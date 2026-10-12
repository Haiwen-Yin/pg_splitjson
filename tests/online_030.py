#!/usr/bin/env python3
"""Online WAL runner correctness, transactional replay and restart assertions."""
import importlib.util
import json
import os
import re
import subprocess
import sys
sys.path.insert(0,os.path.join(os.path.dirname(__file__),'..','scripts'))
from splitjson_libpq import Connection, DatabaseError
spec=importlib.util.spec_from_file_location('splitjson_migrate',os.path.join(os.path.dirname(__file__),'..','scripts','splitjson-migrate.py'))
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)


def ok(value,label):
    if not value: raise AssertionError(label)
    print('PASS:',label)


def fails(db,sql,params,state):
    try: db.execute(sql,params)
    except DatabaseError as error:
        ok(error.state==state,'rejected '+state);return
    raise AssertionError('expected '+state)


def rows(db,relation):
    return db.execute('SELECT id,doc::text,label,tenant::text FROM '+relation+' ORDER BY id')


if len(sys.argv)>1 and sys.argv[1]=='--crash-child':
    with Connection() as child:
        task=runner.Migration(child,int(sys.argv[2]))
        if sys.argv[3]=='before': task.advance(after_apply=lambda _:os._exit(72))
        else: task.advance(after_commit=lambda _:os._exit(73))
    raise AssertionError('crash callback did not execute')


def crash_child(job,phase):
    result=subprocess.run([sys.executable,__file__,'--crash-child',str(job),phase])
    ok(result.returncode==(72 if phase=='before' else 73),'real runner process exits '+phase+' target commit')


with Connection() as db, Connection() as writer:
    db.execute('CREATE EXTENSION pg_splitjson')
    db.execute("SELECT splitjson.create_table('public.online_source','[[\"n\"],[\"a\"],[\"nullable\"]]','{\"label\":\"text\",\"tenant\":\"name\"}')")
    db.execute("INSERT INTO online_source SELECT i,jsonb_build_object('n',0,'a',jsonb_build_array(i,null),'nullable',null,'cold',repeat(md5(i::text),4000)), 'initial','online_a' FROM generate_series(1,3)i")
    db.execute("SELECT splitjson.create_path_index('online_source','online_n_idx',ARRAY['n'],'numeric')")
    db.execute('CREATE ROLE online_a; CREATE ROLE online_b')
    db.execute("SELECT splitjson.enable_rls('online_source'); SELECT splitjson.set_policy('online_source','tenant','all',ARRAY['online_a','online_b'],'tenant=current_user','tenant=current_user',false)")
    job=int(db.execute("SELECT splitjson.prepare_online_migration('online_source','public.online_target','[[\"nullable\"],[\"n\"],[\"a\",0]]','{\"copy\":[\"rls\"],\"role_map\":{\"online_a\":\"online_a\",\"online_b\":\"online_b\"}}') job")[0]['job'])
    task=runner.Migration(db,job)
    source_definition=db.execute("SELECT pg_get_viewdef('online_source'::regclass,true) d")[0]['d']
    def changes():
        writer.execute("SELECT splitjson.increment_field('online_source',1,ARRAY['n'],2)")
        writer.execute("SELECT splitjson.delete_field('online_source',1,ARRAY['nullable'])")
        writer.execute("SELECT splitjson.set_field('online_source',2,ARRAY['cold'],'\"rewritten\"')")
        writer.execute("UPDATE online_source SET id=22,label=NULL WHERE id=2")
        writer.execute("INSERT INTO online_source VALUES(4,'{\"n\":4,\"a\":[5],\"nullable\":null}','new','online_b')")
        writer.execute('DELETE FROM online_source WHERE id=3')
        writer.execute("BEGIN; SELECT splitjson.set_field('online_source',1,ARRAY['n'],'99'); ROLLBACK")
    ok(task.copy(changes)==3,'exported snapshot sees the original id set during writes')
    task.advance()
    ok(rows(db,'online_source')==rows(db,'online_target'),'original-layout state plus WAL restores logical rows under a new layout')
    ok(db.execute("SELECT pg_get_viewdef('online_source'::regclass,true) d")[0]['d']==source_definition,'source view and storage layout remain unchanged')
    status=json.loads(db.execute('SELECT splitjson.migration_status($1::bigint) s',[job])[0]['s'])
    ok(status['state']=='ready' and not status['cutover_ready'],'position-only readiness requires a final writer fence')
    fails(db,"SELECT splitjson.set_field('online_target',1,ARRAY['n'],'9')",None,'25006')
    fails(db,"SELECT splitjson.set_policy('online_source','blocked','select',ARRAY['public'],'true')",None,'55000')
    writer.execute("SELECT splitjson.increment_field('online_source',1,ARRAY['n'])")
    ok(rows(db,'online_source')!=rows(db,'online_target'),'later source writes do not inherit stale ready evidence')
    # Simulate process death after a committed replay transaction and before
    # acknowledgement. Resume must skip that committed transaction, not write it.
    class LostProcess(Exception): pass
    def after_commit(position): raise LostProcess()
    try: task.advance(after_commit=after_commit)
    except LostProcess: pass
    else: raise AssertionError('failure injection did not run')
    revision_before=db.execute("SELECT splitjson.row_revision('online_target',1) r")[0]['r']
    task=runner.Migration(db,job);task.advance()
    ok(db.execute("SELECT splitjson.row_revision('online_target',1) r")[0]['r']==revision_before,'restart acknowledges already-committed progress without duplicate target writes')
    ok(rows(db,'online_source')==rows(db,'online_target'),'restart reaches exact source logical rows')
    result=task.complete()
    ok(result['state']=='completed' and result['rows_equal'] and result['source_retained'],'final fence validates equality and retains source')
    fails(db,"SELECT splitjson.set_field('online_source',1,ARRAY['n'],'9')",None,'25006')
    db.execute("SELECT splitjson.increment_field('online_target',1,ARRAY['n'])")
    ok(db.execute("SELECT splitjson.get_field('online_target',1,ARRAY['n']) value")[0]['value']=='4','new target accepts local hot writes after completion')
    ok(db.execute('SELECT count(*) n FROM pg_replication_slots WHERE slot_name=$1',[task.slot])[0]['n']=='0','completion drops only the task-owned slot')
    # Abort keeps its source and target while releasing only owned resources.
    db.execute("SELECT splitjson.fence_writes('online_source',false)")
    job2=int(db.execute("SELECT splitjson.prepare_online_migration('online_source','public.abort_target','[[\"n\"]]') j")[0]['j'])
    abort=runner.Migration(db,job2);abort.copy();abort.advance()
    db.execute('SELECT splitjson.abort_migration($1::bigint)',[job2])
    ok(json.loads(db.execute('SELECT splitjson.migration_status($1::bigint) s',[job2])[0]['s'])['state']=='aborted','abort persists terminal state')
    ok(db.execute('SELECT count(*) n FROM pg_replication_slots WHERE slot_name=$1',[abort.slot])[0]['n']=='0','abort releases its own slot')
    ok(db.execute('SELECT count(*) n FROM online_source')[0]['n']=='3','abort never mutates source data')
    print('Online migration snapshot/replay/restart/fence assertions passed.')

with Connection() as db,Connection() as writer:
    db.execute("SELECT splitjson.create_partitioned_table('public.crash_source','[[\"n\"],[\"a\",0]]','{\"label\":\"text\",\"tenant\":\"name\"}','[{\"from\":0,\"to\":10},{\"from\":10,\"to\":100}]')")
    db.execute("INSERT INTO crash_source VALUES(1,'{\"n\":1,\"a\":[null,2]}','one','online_a'),(2,'{\"n\":2,\"a\":[3,4]}','two','online_b')")
    job=int(db.execute("SELECT splitjson.prepare_online_migration('crash_source','public.crash_target','[[\"n\"],[\"a\"]]') j")[0]['j'])
    task=runner.Migration(db,job);task.copy(batch_size=1);task.advance()
    before=rows(db,'crash_target')
    writer.execute("BEGIN; SELECT splitjson.increment_field('crash_source',1,ARRAY['n']); UPDATE crash_source SET id=22,label=NULL WHERE id=2; COMMIT")
    crash_child(job,'before')
    ok(rows(db,'crash_target')==before,'process death before commit rolls back the entire source transaction on target')
    task=runner.Migration(db,job);task.advance()
    ok(rows(db,'crash_source')==rows(db,'crash_target'),'partition id move and unchanged TOAST replay atomically after process restart')
    writer.execute("SELECT splitjson.increment_field('crash_source',1,ARRAY['n'])")
    crash_child(job,'after')
    token=db.execute("SELECT splitjson.row_revision('crash_target',1) t")[0]['t']
    task=runner.Migration(db,job);task.advance()
    ok(db.execute("SELECT splitjson.row_revision('crash_target',1) t")[0]['t']==token,'real commit-before-ack crash does not duplicate a target UPDATE')
    writer.execute('BEGIN ISOLATION LEVEL REPEATABLE READ')
    # Pin an old snapshot without retaining a source AccessShareLock, since
    # a correct AccessExclusive writer fence must wait for such locks.
    writer.execute('SELECT count(*) FROM splitjson._tables')
    db.execute("SELECT splitjson.fence_writes('crash_source',true)")
    fails(writer,"SELECT splitjson.increment_field('crash_source',1,ARRAY['n'])",None,'25006')
    writer.execute('ROLLBACK')
    task.complete()
    job2=int(db.execute("SELECT splitjson.prepare_online_migration('crash_target','public.lost_slot_target','[[\"n\"]]') j")[0]['j'])
    lost=runner.Migration(db,job2);lost.copy();lost.advance()
    db.execute('SELECT pg_drop_replication_slot($1)',[lost.slot])
    try: lost.advance()
    except ValueError: pass
    else: raise AssertionError('missing slot accepted')
    status=json.loads(db.execute('SELECT splitjson.migration_status($1::bigint) s',[job2])[0]['s'])
    ok(status['state']=='failed' and status['requires_rebootstrap'] and not status['cutover_ready'],'slot loss persists failure and invalidates cutover readiness')
    db.execute('SELECT splitjson.abort_migration($1::bigint)',[job2])
    print('Online real process crash/partition/old-snapshot/slot-loss assertions passed.')

# Crash ONLY the primary PGDATA owned by the current remote test lab. Resume
# uses its crash-recovered slot and task state, never an existing host instance.
lab=os.environ['PG_SPLITJSON_LAB_ROOT']; pgbin=os.environ['PG_SPLITJSON_LAB_BIN']; data=os.environ['PG_SPLITJSON_LAB_DATA']
assert re.fullmatch(r'/tmp/pg_splitjson-lab\.[A-Za-z0-9]+',lab)
assert pgbin==lab+'/pgsql/bin' and data==lab+'/data' and os.environ['PGHOST']==lab+'/runtime/socket'
with Connection() as db,Connection() as writer:
    job=int(db.execute("SELECT splitjson.prepare_online_migration('crash_target','public.server_crash_target','[[\"n\"]]') j")[0]['j'])
    task=runner.Migration(db,job);task.copy();task.advance()
    writer.execute("SELECT splitjson.increment_field('crash_target',1,ARRAY['n'])")
    def crash_server(_):
        subprocess.check_call([pgbin+'/pg_ctl','-D',data,'-m','immediate','-w','stop'],stdout=subprocess.DEVNULL)
    try: task.advance(after_apply=crash_server)
    except DatabaseError: pass
    else: raise AssertionError('server crash injection did not disconnect')
subprocess.check_call([pgbin+'/pg_ctl','-D',data,'-l',lab+'/runtime/server.log','-o',
    "-k %s -p %s -c listen_addresses='' -c session_preload_libraries=pg_splitjson"%(os.environ['PGHOST'],os.environ['PGPORT']),'-w','start'],stdout=subprocess.DEVNULL)
with Connection() as db:
    task=runner.Migration(db,job);task.advance();task.complete()
    ok(rows(db,'crash_target')==rows(db,'server_crash_target'),'actual PG crash before target commit restores slot/state and replays without loss')
print('Online migration complete fault suite passed.')
