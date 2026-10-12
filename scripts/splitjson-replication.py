#!/usr/bin/env python3
"""Same-layout native logical replication and verified takeover for PG18.

Run as the trusted extension installer on both endpoints. Native PostgreSQL
owns transport, transaction boundaries and TOAST handling. Credentials use a
libpq service/passfile and never enter manifests or reports.
"""
import argparse
import json
import re
import sys
import time
import uuid
from splitjson_libpq import Connection, DatabaseError, identifier, qualified


def literal(value): return "'" + value.replace("'", "''") + "'"
def value(db, sql, params=None):
    rows = db.execute(sql, params)
    return next(iter(rows[0].values())) if rows else None
def json_value(db, sql, params=None): return json.loads(value(db, sql, params) or 'null')
def lsn(raw):
    if not raw: return -1
    high, low = raw.split('/'); return (int(high, 16) << 32) + int(low, 16)
def configure(db):
    db.execute("SET DateStyle='ISO,YMD'; SET TimeZone='UTC'; SET IntervalStyle='postgres'; SET extra_float_digits=3; SET statement_timeout='30s'")


def record(db, table):
    rows = db.execute('SELECT * FROM splitjson._replicas WHERE view_name=splitjson._qualified_name($1::regclass)', [table])
    if len(rows) != 1: raise ValueError('registered replica is missing')
    rows[0]['detail'] = json.loads(rows[0]['detail']); return rows[0]


def private(db, name):
    parts = json.loads(value(db, 'SELECT to_json(parse_ident($1,true)) value', [name]))
    if len(parts) != 2 or parts[0] != 'splitjson_storage': raise ValueError('private relation name is invalid')
    return qualified(parts)


def prepare(source, target, table, target_table, copy=None, role_map=None):
    configure(source); configure(target)
    manifest = json_value(source, 'SELECT splitjson.replication_manifest($1::regclass,$2::jsonb)',
                          [table, json.dumps(copy or ['collation'])])
    return json_value(target, 'SELECT splitjson.prepare_replica_manifest($1::jsonb,$2,$3::jsonb)',
                      [json.dumps(manifest), target_table, json.dumps({'role_map': role_map or {}})])


def start(source, target, table, target_table, source_conninfo):
    configure(source); configure(target)
    r = record(target, target_table); info = r['detail']; manifest = info['manifest']
    current = json_value(source, 'SELECT splitjson.replication_manifest($1::regclass)', [table])
    if (current['layout_fingerprint'], current['publisher_systemid'], current['storage']) != \
       (manifest['layout_fingerprint'], manifest['publisher_systemid'], manifest['storage']):
        raise ValueError('publisher changed since subscriber preparation')
    if r['state'] != 'prepared': raise ValueError('replica is not prepared')
    nonce = uuid.uuid4().hex[:20]
    publication = 'sj_rep_' + nonce + '_pub'; subscription = 'sj_rep_' + nonce + '_sub'; slot = 'sj_rep_' + nonce + '_slot'
    barrier = 'splitjson_storage.sj_barrier_' + nonce
    if re.search(r'password\s*=|://[^/@]*:[^/@]*@', source_conninfo, re.I):
        raise ValueError('use a libpq service/passfile instead of a password in connection info')
    for db in (source, target):
        db.execute('CREATE TABLE ' + private(db, barrier) + '(id integer PRIMARY KEY CHECK(id=1),token text NOT NULL)')
        db.execute('SELECT splitjson._secure_relation($1::regclass)', [barrier])
    source_fingerprint = value(source, 'SELECT splitjson._capture_fingerprint(m) FROM splitjson._tables m WHERE view_name=$1', [current['view']])
    detail = {'barrier_table': barrier, 'slot_name': slot, 'source_storage': manifest['storage'],
              'target_storage': r['detail']['target_storage'], 'publisher_systemid': manifest['publisher_systemid'],
              'source_fingerprint': source_fingerprint}
    source.execute("INSERT INTO splitjson._replicas(view_name,source_view,publication_name,subscription_name,state,fingerprint,detail) "
                   "VALUES($1,$1,$2,$3,'publishing',$4,$5::jsonb)",
                   [current['view'], publication, subscription, current['layout_fingerprint'], json.dumps(detail)])
    target.execute('UPDATE splitjson._replicas SET detail=detail||$2::jsonb WHERE view_name=$1',
                   [r['view_name'], json.dumps({k: v for k, v in detail.items() if k != 'source_fingerprint'})])
    source.execute('CREATE PUBLICATION ' + identifier(publication) + ' FOR TABLE ' + private(source, manifest['storage']) + ',' + private(source, barrier) +
                   " WITH (publish_via_partition_root=true,publish='insert,update,delete')")
    target.execute('CREATE SUBSCRIPTION ' + identifier(subscription) + ' CONNECTION ' + literal(source_conninfo) + ' PUBLICATION ' + identifier(publication) +
                   " WITH (copy_data=true,create_slot=true,enabled=true,slot_name=" + literal(slot) + ',streaming=off)')
    target.execute('SELECT splitjson.register_replica_subscription($1::regclass,$2::name,$3::name)', [target_table, subscription, publication])
    return {'state': 'running', 'source': current['view'], 'target': r['view_name'], 'publication': publication,
            'subscription': subscription, 'slot': slot, 'credentials': None}


def status(target, table, source=None):
    result = json_value(target, 'SELECT splitjson.replication_status($1::regclass)', [table])
    if result is None: return None
    if source:
        slot = result['detail'].get('slot_name')
        rows = source.execute('SELECT plugin,wal_status,invalidation_reason,active,confirmed_flush_lsn::text,restart_lsn::text,'
                              'pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)::text retained_bytes FROM pg_replication_slots WHERE slot_name=$1', [slot])
        result['publisher_slot'] = rows[0] if rows else None
        result['requires_rebootstrap'] = not rows or rows[0]['wal_status'] == 'lost' or rows[0]['plugin'] != 'pgoutput'
    return result


def wait_for(target, table, predicate, source=None, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        current = status(target, table, source)
        if current is None or current.get('requires_rebootstrap'): raise ValueError('subscription/retained WAL unavailable; rebootstrap required')
        if predicate(current): return current
        time.sleep(.1)
    raise ValueError('native replication did not reach required state in time')


def stop(target, table, timeout=60):
    target.execute('SELECT splitjson.stop_replica($1::regclass)', [table])
    return wait_for(target, table, lambda s: s['subscription_enabled'] is False and s['active_workers'] == 0, timeout=timeout)


def resume(target, table):
    r = record(target, table)
    if r['state'] != 'stopped' or not r['subscription_name']: raise ValueError('stopped registered subscription required')
    target.execute('ALTER SUBSCRIPTION ' + identifier(r['subscription_name']) + ' ENABLE')
    target.execute("UPDATE splitjson._replicas SET state='running',detail=detail-'fence' WHERE view_name=$1", [r['view_name']])
    return {'state': 'running', 'target': r['view_name']}


def logical_rows(db, table):
    return [r['row'] for r in db.execute('SELECT r::text row FROM splitjson.export_rows($1::regclass) r', [table])]


def takeover(source, target, table, target_table, timeout=60):
    configure(source); configure(target); r = record(target, target_table); info = r['detail']; sr = record(source, table)
    if sr['publication_name'] != r['publication_name'] or sr['detail'].get('barrier_table') != info.get('barrier_table'):
        raise ValueError('publisher/subscriber ownership mismatch')
    wait_for(target, target_table, lambda s: s['synced'] is True, source, timeout)
    token = uuid.uuid4().hex
    source.execute('BEGIN')
    try:
        fence = value(source, 'SELECT splitjson.fence_writes($1::regclass,true)', [table])
        source.execute('INSERT INTO ' + private(source, info['barrier_table']) + ' VALUES(1,$1) ON CONFLICT(id) DO UPDATE SET token=EXCLUDED.token', [token])
        source.execute('COMMIT')
    except BaseException:
        source.execute('ROLLBACK'); raise
    def reached(s):
        marker = value(target, 'SELECT token FROM ' + private(target, info['barrier_table']) + ' WHERE id=1')
        return marker == token and s['synced'] is True and lsn(s.get('target_confirmed_lsn')) >= lsn(fence)
    wait_for(target, target_table, reached, source, timeout)
    stop(target, target_table, timeout)
    if logical_rows(source, table) != logical_rows(target, target_table): raise ValueError('logical rows differ at final fence')
    target.execute('UPDATE splitjson._replicas SET final_lsn=$2::pg_lsn,detail=detail||$3::jsonb WHERE view_name=$1',
                   [r['view_name'], fence, json.dumps({'fence': {'token': token, 'lsn': fence, 'rows_equal': True, 'publisher_systemid': info['publisher_systemid']}})])
    return json_value(target, 'SELECT splitjson.takeover_replica($1::regclass,$2::pg_lsn,true)', [target_table, fence])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'start', 'status', 'stop', 'resume', 'takeover'))
    parser.add_argument('--source-service'); parser.add_argument('--source'); parser.add_argument('--target', required=True)
    parser.add_argument('--copy', default='collation'); parser.add_argument('--role-map', default='{}'); parser.add_argument('--timeout', type=int, default=60)
    args = parser.parse_args()
    if args.command not in ('status', 'stop', 'resume') and (not args.source_service or not args.source): parser.error('this command requires --source-service and --source')
    if args.source_service and not re.fullmatch(r'[A-Za-z0-9_.-]+', args.source_service): parser.error('invalid libpq service name')
    try:
        with Connection() as target:
            if args.command == 'stop': output = stop(target, args.target, args.timeout)
            elif args.command == 'resume': output = resume(target, args.target)
            elif not args.source_service: output = status(target, args.target)
            else:
                with Connection('service=' + args.source_service) as source:
                    if args.command == 'prepare': output = prepare(source, target, args.source, args.target, args.copy.split(',') if args.copy else [], json.loads(args.role_map))
                    elif args.command == 'start': output = start(source, target, args.source, args.target, 'service=' + args.source_service)
                    elif args.command == 'status': output = status(target, args.target, source)
                    else: output = takeover(source, target, args.source, args.target, args.timeout)
        print(json.dumps(output, sort_keys=True))
    except (DatabaseError, ValueError, OSError):
        print('Replication preconditions/native progress failed; inspect registered status. No connection settings are logged.', file=sys.stderr); return 1
    return 0


if __name__ == '__main__': sys.exit(main())
