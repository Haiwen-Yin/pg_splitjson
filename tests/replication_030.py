#!/usr/bin/env python3
"""Native pgoutput test with two PGDATA owned by the isolated lab."""
import importlib.util
import json
import os
import re
import subprocess
import sys
sys.path.insert(0,os.path.join(os.path.dirname(__file__),'..','scripts'))
from splitjson_libpq import Connection, DatabaseError, identifier
spec=importlib.util.spec_from_file_location('replication',os.path.join(os.path.dirname(__file__),'..','scripts','splitjson-replication.py'))
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
lab=os.environ['PG_SPLITJSON_LAB_ROOT'];pgbin=os.environ['PG_SPLITJSON_LAB_BIN']
assert re.fullmatch(r'/tmp/pg_splitjson-lab\.[A-Za-z0-9]+',lab) and pgbin==lab+'/pgsql/bin'
assert os.environ['PGHOST']==lab+'/runtime/socket'
target_conninfo='host=%s/runtime/subscriber-socket port=65421 user=%s dbname=postgres'%(lab,os.environ['PGUSER'])
source_conninfo='host=%s port=%s user=%s dbname=%s'%(os.environ['PGHOST'],os.environ['PGPORT'],os.environ['PGUSER'],os.environ['PGDATABASE'])


def ok(value,label):
    if not value: raise AssertionError(label)
    print('PASS:',label,flush=True)


def fails(db,sql,state):
    try: db.execute(sql)
    except DatabaseError as error:
        ok(error.state==state,'rejected '+state);return
    raise AssertionError('expected '+state)


def equal(source,target,a,b): return runner.logical_rows(source,a)==runner.logical_rows(target,b)


with Connection() as source,Connection(target_conninfo) as target,Connection() as writer:
    source.execute('CREATE EXTENSION IF NOT EXISTS pg_splitjson');target.execute('CREATE EXTENSION pg_splitjson')
    for db in (source,target):db.execute('CREATE ROLE repl_a;CREATE ROLE repl_b')
    source.execute("SELECT splitjson.create_table('public.repl_source','[[\"n\"],[\"a\",1],[\"state\"]]','{\"label\":\"text\",\"tenant\":\"name\",\"tags\":\"integer[]\",\"score\":\"numeric(15,3)\"}')")
    source.execute("SELECT splitjson.create_path_index('repl_source','repl_n_idx',ARRAY['n'],'numeric')")
    source.execute("SELECT splitjson.enable_rls('repl_source');SELECT splitjson.set_policy('repl_source','tenant','all',ARRAY['repl_a','repl_b'],'tenant=current_user','tenant=current_user',false)")
    source.execute("SELECT splitjson.grant_access('repl_source','repl_a','write');SELECT splitjson.grant_access('repl_source','repl_b','write')")
    source.execute("INSERT INTO repl_source SELECT i,jsonb_build_object('n',i,'a',jsonb_build_array(i,null),'state','new','cold',(SELECT string_agg(md5(x::text),'') FROM generate_series(1,4096)x)), 'old',123.450,'[0:1]={1,2}'::int[],'repl_a' FROM generate_series(1,5)i")
    prepared=runner.prepare(source,target,'repl_source','public.repl_target',['indexes','rls','acl','collation'],{'repl_a':'repl_a','repl_b':'repl_b'})
    ok(prepared['state']=='prepared','subscriber provisions same physical names and private local metadata from manifest')
    fails(target,"SELECT splitjson.increment_field('repl_target',1,ARRAY['n'])",'25006')
    started=runner.start(source,target,'repl_source','repl_target',source_conninfo)
    writer.execute("SELECT splitjson.set_fields('repl_source',1,'[{\"path\":[\"n\"],\"value\":11},{\"path\":[\"state\"],\"value\":\"ready\"}]')")
    writer.execute("UPDATE repl_source SET label=NULL,score=999.125 WHERE id=2")
    writer.execute("SELECT splitjson.apply_patch('repl_source',3,'[{\"op\":\"add\",\"path\":\"/a/0\",\"value\":100}]')")
    writer.execute("SELECT splitjson.set_field('repl_source',4,ARRAY['cold'],'\"changed\"')")
    writer.execute("BEGIN;SELECT splitjson.set_field('repl_source',1,ARRAY['n'],'999');DELETE FROM repl_source WHERE id=2;ROLLBACK")
    runner.wait_for(target,'repl_target',lambda s:s['synced'] and equal(source,target,'repl_source','repl_target'),source)
    ok(equal(source,target,'repl_source','repl_target'),'initial sync and concurrent hot/cold/array/typed-business/rollback changes agree')
    ok(runner.value(source,"SELECT split_part(splitjson.row_revision('repl_source',1),':',3)")==runner.value(target,"SELECT split_part(splitjson.row_revision('repl_target',1),':',3)"),'native apply preserves publisher revision without an origin trigger increment')
    target.execute('SET ROLE repl_a')
    ok(runner.value(target,'SELECT count(*) FROM repl_target')=='5','replicated RLS uses local application role')
    fails(target,'SELECT * FROM '+prepared['storage'],'42501')
    fails(target,"UPDATE repl_target SET doc='{}' WHERE id=1",'25006')
    target.execute('RESET ROLE;SET ROLE repl_b')
    ok(runner.value(target,'SELECT count(*) FROM repl_target')=='0','subscriber policies filter complete trusted replication data')
    target.execute('RESET ROLE')
    stopped=runner.stop(target,'repl_target')
    fails(target,"SELECT splitjson.takeover_replica('repl_target','0/1',true)",'55000')
    writer.execute("SELECT splitjson.increment_field('repl_source',1,ARRAY['n'])")
    ok(not equal(source,target,'repl_source','repl_target'),'paused subscription exposes unapplied backlog')
    runner.resume(target,'repl_target')
    runner.wait_for(target,'repl_target',lambda s:equal(source,target,'repl_source','repl_target'),source)
    pid=runner.value(target,"SELECT pid FROM pg_stat_subscription WHERE subname=$1 AND worker_type='apply'",[started['subscription']])
    if pid:target.execute('SELECT pg_terminate_backend($1::integer)',[pid])
    writer.execute("SELECT splitjson.increment_field('repl_source',1,ARRAY['n'])")
    runner.wait_for(target,'repl_target',lambda s:equal(source,target,'repl_source','repl_target'),source)
    ok(True,'registered native apply worker restarts and catches up retained transactions')
    promoted=runner.takeover(source,target,'repl_source','repl_target')
    ok(promoted['state']=='promoted' and promoted['native_workers_stopped'],'takeover verifies actual source fence marker, apply position, worker stop and row equality')
    fails(source,"SELECT splitjson.increment_field('repl_source',1,ARRAY['n'])",'25006')
    token=runner.value(target,"SELECT splitjson.row_revision('repl_target',1)")
    target.execute("SELECT splitjson.increment_field('repl_target',1,ARRAY['n'])")
    ok(runner.value(target,"SELECT splitjson.row_revision('repl_target',1)")!=token,'promoted target allocates new local revision and accepts hot API')
    # Partition publication routes physical row moves via the canonical root.
    source.execute("SELECT splitjson.create_partitioned_table('public.repl_part_source','[[\"n\"],[\"a\",0]]','{}','[{\"from\":0,\"to\":10},{\"from\":10,\"to\":100}]')")
    source.execute("SELECT splitjson.create_partition('repl_part_source','extra_range',100,200)")
    source.execute("INSERT INTO repl_part_source VALUES(1,'{\"n\":1,\"a\":[null,2]}'),(101,'{\"n\":101}')")
    runner.prepare(source,target,'repl_part_source','public.repl_part_target')
    part=runner.start(source,target,'repl_part_source','repl_part_target',source_conninfo)
    source.execute("UPDATE repl_part_source SET id=22 WHERE id=1")
    source.execute("SELECT splitjson.upsert_document('repl_part_source',102,'{\"n\":102,\"a\":[1]}')")
    runner.wait_for(target,'repl_part_target',lambda s:s['synced'] and equal(source,target,'repl_part_source','repl_part_target'),source)
    ok(equal(source,target,'repl_part_source','repl_part_target'),'root publication copies updated RANGE layout and routes cross-partition id moves')
    fails(source,"SELECT splitjson.create_partition('repl_part_source','blocked_range',200,300)",'55000')
    runner.takeover(source,target,'repl_part_source','repl_part_target')
    ok(True,'partitioned replica takeover passed')
print('Native replication complete assertion suite passed.',flush=True)
