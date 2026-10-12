#!/usr/bin/env python3
"""Managed online layout migration for PG18.6.

Uses a slot-exported snapshot, persistent original-layout state, and committed
source transactions. Target rows and progress commit together before WAL ack.
Connection settings use libpq environment/service; reports never contain data
values or credentials. The source stays in place and cutover remains manual.
"""
import argparse
import importlib.util
import json
import re
import sys
from splitjson_libpq import Connection, DatabaseError, identifier, qualified


def lsn(value):
    high, low=value.split('/')
    return (int(high,16)<<32)+int(low,16)


def configure(db):
    db.execute("SET DateStyle='ISO,YMD'; SET TimeZone='UTC'; SET IntervalStyle='postgres'; SET extra_float_digits=3")


class Migration:
    def __init__(self, db, job):
        self.db=db; self.job=int(job); configure(db)
        rows=db.execute('SELECT * FROM splitjson._jobs WHERE id=$1::bigint',[self.job])
        if len(rows)!=1: raise ValueError('migration task is missing')
        self.info=rows[0]
        self.source=self.info['source_name']; self.target=self.info['target_name']; self.slot=self.info['slot_name']
        if not re.fullmatch(r'sj_job_%d_[a-f0-9]{12}'%self.job,self.slot): raise ValueError('slot ownership mismatch')
        self.source_meta=self._meta(self.source); self.target_meta=self._meta(self.target)
        self.source_sql=self._relation(self.source_meta['storage_name'])
        self.target_sql=self._relation(self.target_meta['storage_name'])
        self.source_columns=self._columns(self.source_meta['storage_name'])
        self.target_columns=self._columns(self.target_meta['storage_name'])
        self.source_oid=int(db.execute('SELECT $1::regclass::oid oid',[self.source_meta['storage_name']])[0]['oid'])
        self.source_relations={int(r['oid']) for r in db.execute('SELECT relid::oid oid FROM pg_partition_tree($1::regclass)',[self.source_meta['storage_name']])}
        self.source_relations.add(self.source_oid)

    def _meta(self, relation):
        rows=self.db.execute('SELECT to_jsonb(m) value FROM splitjson._tables m WHERE view_name=$1',[relation])
        if len(rows)!=1: raise ValueError('managed relation is missing')
        return json.loads(rows[0]['value'])

    def _relation(self, relation):
        parts=json.loads(self.db.execute('SELECT to_json(parse_ident($1,true)) value',[relation])[0]['value'])
        if len(parts)!=2 or parts[0]!='splitjson_storage': raise ValueError('unexpected storage namespace')
        return qualified(parts)

    def _columns(self, relation):
        return self.db.execute('SELECT attname name,format_type(atttypid,atttypmod) type,format_type(atttypid,NULL) protocol_type FROM pg_attribute '
                              'WHERE attrelid=$1::regclass AND attnum>0 AND NOT attisdropped ORDER BY attnum',[relation])

    def _mark(self,state,position=None,detail=None):
        self.db.execute('SELECT splitjson.mark_migration_state($1::bigint,$2,$3::pg_lsn,$4::jsonb)',
                        [self.job,state,position,json.dumps(detail or {})])

    def _read_state(self,row_id):
        result=self.db.execute('SELECT columns FROM splitjson._migration_rows WHERE job_id=$1::bigint AND id=$2::bigint',
                               [self.job,row_id])
        return json.loads(result[0]['columns']) if result else None

    def _delete(self,row_id):
        self.db.execute('DELETE FROM splitjson._migration_rows WHERE job_id=$1::bigint AND id=$2::bigint',[self.job,row_id])
        self.db.execute('DELETE FROM '+self.target_sql+' WHERE id=$1::bigint',[row_id])

    def _write(self,state):
        # SQL NULL hot slots are native NULL parameters. Full values remain raw
        # JSON text, so numeric precision never round-trips through Python float.
        hot_count=len(self.source_meta['paths'])
        restore_args=','.join('$%d::jsonb'%(i+2) for i in range(hot_count))
        params=[state['cold']]+[state['hot_%d'%(i+1)] for i in range(hot_count)]
        params.append(json.dumps(self.source_meta['paths']))
        doc=self.db.execute('SELECT splitjson.restore($1::splitjson.cold,ARRAY['+restore_args+']::jsonb[],$%d::jsonb)::text doc'%(hot_count+2),params)[0]['doc']
        new_hot=len(self.target_meta['paths'])
        projections=['cold::text cold']+['(slots)[%d]::text hot_%d'%(i,i) for i in range(1,new_hot+1)]
        packed=self.db.execute('WITH p AS MATERIALIZED (SELECT splitjson.pack($1::jsonb,$2::jsonb) cold,splitjson.slots($1::jsonb,$2::jsonb) slots) SELECT '+
                               ','.join(projections)+' FROM p',[doc,json.dumps(self.target_meta['paths'])])[0]
        columns=[c for c in self.target_columns if c['name']!='row_revision']
        values=[state[c['name']] if c['name']=='id' or c['name'].startswith('extra_') else packed[c['name']] for c in columns]
        names=','.join(identifier(c['name']) for c in columns)
        placeholders=','.join('$%d::%s'%(i+1,c['type']) for i,c in enumerate(columns))
        assignments=','.join(identifier(c['name'])+'=EXCLUDED.'+identifier(c['name']) for c in columns if c['name']!='id')
        self.db.execute('INSERT INTO '+self.target_sql+'('+names+') VALUES('+placeholders+') ON CONFLICT(id) DO UPDATE SET '+assignments,values)
        self.db.execute('INSERT INTO splitjson._migration_rows(job_id,id,columns) VALUES($1::bigint,$2::bigint,$3::jsonb) '
                        'ON CONFLICT(job_id,id) DO UPDATE SET columns=EXCLUDED.columns',[self.job,state['id'],json.dumps(state)])

    def copy(self,after_snapshot=None,batch_size=1000):
        if self.info['state']!='prepare': raise ValueError('snapshot copy requires prepare state')
        if not 1<=batch_size<=10000: raise ValueError('copy batch size must be between 1 and 10000')
        exporter=Connection('replication=database'); reader=Connection(); created=False
        try:
            gate=exporter.execute('CREATE_REPLICATION_SLOT '+identifier(self.slot)+' LOGICAL pg_splitjson_decode (SNAPSHOT \'export\')')[0]
            created=True; snapshot=gate['snapshot_name']; start=gate['consistent_point']
            if not re.fullmatch(r'[A-Fa-f0-9-]+',snapshot): raise ValueError('invalid exported snapshot identifier')
            configure(reader); reader.execute('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
            reader.execute("SET TRANSACTION SNAPSHOT '"+snapshot+"'")
            self._mark('copying',start,{'snapshot_complete':False})
            if after_snapshot: after_snapshot()
            # Keep the exporting backend alive through scan + target commit.
            reader.execute('DECLARE sj_copy NO SCROLL CURSOR FOR SELECT '+','.join(identifier(c['name'])+'::text AS '+identifier(c['name']) for c in self.source_columns)+
                           ' FROM '+self.source_sql+' ORDER BY id')
            copied=0
            while True:
                rows=reader.execute('FETCH FORWARD %d FROM sj_copy'%batch_size)
                if not rows: break
                self.db.execute('BEGIN')
                try:
                    for row in rows: self._write(row)
                    self.db.execute('COMMIT'); copied+=len(rows)
                except BaseException:
                    self.db.execute('ROLLBACK'); raise
            self._mark('catching_up',start,{'snapshot_complete':True,'copied_rows':copied})
            reader.execute('COMMIT')
            return copied
        except BaseException:
            try: self._mark('failed',None,{'failure':'snapshot handshake/copy failed; rebootstrap required','snapshot_complete':False})
            except BaseException: pass
            raise
        finally:
            reader.close(); exporter.close()

    def _apply(self,change):
        if change.get('v')!=1: raise ValueError('unsupported decoding protocol')
        if change.get('source')!=self.source_oid or change.get('relation') not in self.source_relations:
            raise ValueError('event is not for the registered source layout')
        old=change.get('old'); new=change.get('new')
        old_id=old and old.get('id') and old['id'].get('text')
        new_id=new and new.get('id') and new['id'].get('text')
        if change['event']=='delete':
            if old_id is None or self._read_state(old_id) is None: raise ValueError('DELETE original state is missing')
            self._delete(old_id); return
        previous=self._read_state(old_id or new_id)
        if change['event']=='update' and previous is None: raise ValueError('UPDATE original state is missing')
        if change['event']=='insert' and previous is not None: raise ValueError('INSERT original state already exists')
        state=dict(previous or {})
        for column in self.source_columns:
            name=column['name']
            if name not in new: raise ValueError('WAL column presence bitmap is incomplete')
            value=new[name]
            if value and not value.get('unchanged') and value.get('type')!=column['protocol_type']:
                raise ValueError('WAL column type disagrees with snapshot layout')
            if value and value.get('unchanged'):
                if name not in state: raise ValueError('unchanged TOAST lacks original state; rebootstrap required')
            else: state[name]=None if value is None else value['text']
        if state.get('id') is None or state.get('cold') is None: raise ValueError('WAL lacks identity/document')
        if old_id and old_id!=new_id: self._delete(old_id)
        self._write(state)

    def advance(self,until=None,after_commit=None,after_apply=None):
        try:
            return self._advance(until,after_commit,after_apply)
        except BaseException:
            try: self._mark('failed',None,{'failure':'replay/slot/protocol failed; inspect status before resume'})
            except BaseException: pass
            raise

    def _advance(self,until,after_commit,after_apply):
        status=json.loads(self.db.execute('SELECT splitjson.migration_status($1::bigint) value',[self.job])[0]['value'])
        if status['state'] in ('prepare','copying','aborted','completed') or not status['detail'].get('snapshot_complete'):
            raise ValueError('complete snapshot state is required; restart copy if its snapshot was lost')
        slot=status.get('slot')
        if not slot or slot.get('wal_status')=='lost' or not status['fingerprint_valid']:
            raise ValueError('slot/WAL/fingerprint invalid; rebootstrap required')
        progress=status['confirmed_lsn']
        if lsn(slot['confirmed_flush_lsn'])>lsn(progress): raise ValueError('slot was advanced beyond committed task progress')
        if until is None: until=self.db.execute('SELECT pg_current_wal_lsn() lsn')[0]['lsn']
        if lsn(until)<lsn(progress): raise ValueError('requested replay boundary precedes committed progress')
        events=self.db.execute("SELECT data FROM pg_logical_slot_peek_changes($1,$2::pg_lsn,NULL,'source',$3)",[self.slot,until,self.source])
        pending=None; count=0
        for row in events:
            event=json.loads(row['data'])
            if event.get('v')!=1: raise ValueError('unsupported decoding protocol')
            if event['event']=='begin':
                if pending is not None: raise ValueError('nested transaction event')
                pending=[]
            elif event['event']=='commit':
                if pending is None: raise ValueError('commit without begin')
                end=event['end_lsn']
                if lsn(end)>lsn(until): raise ValueError('decoded transaction exceeds requested boundary')
                if lsn(end)>lsn(progress) and pending:
                    self.db.execute('BEGIN')
                    try:
                        for change in pending: self._apply(change)
                        if after_apply: after_apply(end)
                        self._mark('catching_up',end)
                        self.db.execute('COMMIT')
                    except BaseException:
                        self.db.execute('ROLLBACK'); raise
                    progress=end; count+=len(pending)
                    if after_commit: after_commit(end)
                # This acknowledgement always follows the target+state commit.
                pending=None
            else:
                if pending is None: raise ValueError('change outside transaction')
                pending.append(event)
        if pending is not None: raise ValueError('incomplete source transaction')
        # Empty/unrelated WAL may end after the last emitted commit. Advancing
        # is safe only after all events through the fixed boundary were applied.
        self.db.execute('BEGIN')
        try: self._mark('ready',until,{'last_applied_changes':count}); self.db.execute('COMMIT')
        except BaseException: self.db.execute('ROLLBACK'); raise
        advanced=self.db.execute('SELECT pg_replication_slot_advance($1,$2::pg_lsn) confirmed',[self.slot,until])[0]
        return {'job':self.job,'state':'ready','position':until,'changes':count,'source_retained':True,'cutover_requires_fence':True}

    def complete(self):
        fence=self.db.execute('SELECT splitjson.fence_writes($1::regclass,true) lsn',[self.source])[0]['lsn']
        self.advance(fence)
        return json.loads(self.db.execute('SELECT splitjson.complete_migration($1::bigint,$2::pg_lsn,true) value',[self.job,fence])[0]['value'])


def main():
    parser=argparse.ArgumentParser(description=__doc__); sub=parser.add_subparsers(dest='command')
    p=sub.add_parser('start'); p.add_argument('--source',required=True); p.add_argument('--target',required=True); p.add_argument('--paths',required=True); p.add_argument('--options',default='{}')
    for cmd in ('advance','status','abort','complete'):
        p=sub.add_parser(cmd); p.add_argument('--job',required=True,type=int)
        if cmd=='advance': p.add_argument('--until')
    args=parser.parse_args()
    if args.command is None: parser.error('a command is required')
    try:
        with Connection() as db:
            if args.command=='start':
                job=int(db.execute('SELECT splitjson.prepare_online_migration($1::regclass,$2,$3::jsonb,$4::jsonb) job',
                                   [args.source,args.target,args.paths,args.options])[0]['job'])
                task=Migration(db,job); task.copy(); output=task.advance()
            elif args.command=='status': output=json.loads(db.execute('SELECT splitjson.migration_status($1::bigint) value',[args.job])[0]['value'] or 'null')
            elif args.command=='abort': db.execute('SELECT splitjson.abort_migration($1::bigint)',[args.job]); output={'job':args.job,'state':'aborted','target_retained':True}
            elif args.command=='complete': output=Migration(db,args.job).complete()
            else: output=Migration(db,args.job).advance(args.until)
        print(json.dumps(output,sort_keys=True))
    except (DatabaseError,ValueError,OSError) as error:
        print(str(error) if isinstance(error,DatabaseError) else 'Migration protocol/preconditions failed; task requires review.',file=sys.stderr)
        return 1
    return 0

if __name__=='__main__': sys.exit(main())
