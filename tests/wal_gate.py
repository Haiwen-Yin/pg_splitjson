#!/usr/bin/env python3
"""Prove exported-slot snapshot + unchanged-TOAST replay in an isolated lab."""
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from splitjson_libpq import Connection


def assert_equal(actual, expected, label):
    if actual != expected:
        raise AssertionError(label)
    print("PASS:", label)


with Connection() as db:
    db.execute("CREATE EXTENSION pg_splitjson VERSION '0.2.0'")
    db.execute("SELECT splitjson.create_table('public.wal_docs',"
               "'[[\"counter\"],[\"present\"],[\"nullable\"],[\"blob\"]]', '{\"label\":\"text\"}')")
    db.execute("INSERT INTO wal_docs SELECT i, jsonb_build_object('counter',0,'present',true,'nullable',null,"
               "'blob',repeat(md5(i::text),400),'cold',repeat(md5((i+10)::text),4000)), 'initial' FROM generate_series(1,3) i")
    db.execute("CREATE TABLE unrelated(id bigint PRIMARY KEY); INSERT INTO unrelated VALUES(1)")
    storage = db.execute("SELECT splitjson.storage_relation('wal_docs')::text AS storage")[0]['storage']
    slot = "splitjson_gate_" + str(os.getpid())
    exporter = Connection("replication=database")
    snapshot_reader = Connection()
    slot_created = False
    try:
        gate = exporter.execute(f"CREATE_REPLICATION_SLOT {slot} LOGICAL pg_splitjson_decode (SNAPSHOT 'export')")[0]
        slot_created = True
        snapshot = gate['snapshot_name']
        assert re.fullmatch(r"[A-Fa-f0-9-]+", snapshot)
        print("Bound snapshot:", snapshot, "consistent LSN:", gate['consistent_point'])
        snapshot_reader.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        snapshot_reader.execute(f"SET TRANSACTION SNAPSHOT '{snapshot}'")
        # Source writes continue after importing the slot snapshot, and before
        # scanning any rows. COPY-backfill must see precisely the old state.
        db.execute("SELECT splitjson.increment_field('wal_docs',1,ARRAY['counter'],2)")
        db.execute("SELECT splitjson.delete_field('wal_docs',1,ARRAY['present'])")
        db.execute("SELECT splitjson.set_field('wal_docs',2,ARRAY['cold'],'\"rewritten\"')")
        db.execute("UPDATE wal_docs SET id=22,label=NULL WHERE id=2")
        db.execute("INSERT INTO wal_docs VALUES(4,'{\"counter\":4,\"present\":null,\"blob\":[]}','new')")
        db.execute("DELETE FROM wal_docs WHERE id=3")
        db.execute("BEGIN; SELECT splitjson.set_field('wal_docs',1,ARRAY['counter'],'99'); ROLLBACK")
        db.execute("UPDATE unrelated SET id=2")
        rows = snapshot_reader.execute(f"SELECT id::text,cold::text,hot_1::text,hot_2::text,hot_3::text,hot_4::text,extra_1::text FROM {storage} ORDER BY id")
        state = {row['id']: dict(row) for row in rows}
        assert_equal(sorted(state), ['1', '2', '3'], 'snapshot includes old id set despite concurrent writes')
        assert_equal(state['1']['hot_1'], '0', 'snapshot keeps old hot value')
        snapshot_reader.execute("COMMIT")
        exporter.close()
        events = [json.loads(row['data']) for row in db.execute(
            "SELECT data FROM pg_logical_slot_peek_changes($1,NULL,NULL,'source','public.wal_docs')", [slot])]
        unchanged = sql_null = json_null = id_move = False
        pending = None
        commits = 0
        for event in events:
            assert event['v'] == 1
            if event['event'] == 'begin':
                assert pending is None
                pending = []
            elif event['event'] == 'commit':
                assert pending is not None
                for change in pending:
                    old, new = change['old'], change['new']
                    old_id = old and old['id'] and old['id']['text']
                    new_id = new and new['id'] and new['id']['text']
                    if change['event'] == 'delete':
                        del state[old_id]
                        continue
                    current = state.pop(old_id, {}) if old_id else dict(state.get(new_id, {}))
                    id_move |= bool(old_id and old_id != new_id)
                    for column, value in new.items():
                        if value and value.get('unchanged'):
                            assert column in current, 'unchanged-TOAST needs snapshot state'
                            unchanged = True
                        else:
                            sql_null |= value is None
                            json_null |= bool(column.startswith('hot_') and value and value['text'] == 'null')
                            current[column] = None if value is None else value['text']
                    state[new_id] = current
                commits += 1
                pending = None
            else:
                assert pending is not None
                pending.append(event)
        assert pending is None
        source = db.execute(f"SELECT id::text,cold::text,hot_1::text,hot_2::text,hot_3::text,hot_4::text,extra_1::text FROM {storage} ORDER BY id")
        assert_equal(state, {row['id']: dict(row) for row in source}, 'snapshot plus committed WAL reconstructs exact storage state')
        assert_equal((unchanged, sql_null, json_null, id_move), (True, True, True, True), 'distinct unchanged-TOAST / SQL NULL / JSON null / id movement')
        assert_equal(state['1']['hot_1'], '2', 'rolled-back write absent')
        db.execute("CREATE TEMP TABLE gate_state(LIKE " + storage + " INCLUDING ALL)")
        for row in state.values():
            db.execute("INSERT INTO gate_state VALUES($1::bigint,$2::splitjson.cold,$7::text,$3::jsonb,$4::jsonb,$5::jsonb,$6::jsonb)",
                       [row[k] for k in ('id', 'cold', 'hot_1', 'hot_2', 'hot_3', 'hot_4', 'extra_1')])
        logical = db.execute("SELECT id,splitjson.restore(cold,ARRAY[hot_1,hot_2,hot_3,hot_4])::text AS doc,extra_1 AS label FROM gate_state ORDER BY id")
        assert_equal(logical, db.execute("SELECT id,doc::text,label FROM wal_docs ORDER BY id"), 'merged column states restore full logical documents')
        last = [e for e in events if e['event'] == 'commit'][-1]['end_lsn']
        db.execute("SELECT pg_replication_slot_advance($1,$2::pg_lsn)", [slot, last])
        print("Commit boundaries replayed:", commits)
        print("Protocol v1 WAL/snapshot gate passed; source schema and replica identity unchanged.")
    finally:
        snapshot_reader.close()
        exporter.close()
        if slot_created:
            db.execute("SELECT pg_drop_replication_slot($1)", [slot])
