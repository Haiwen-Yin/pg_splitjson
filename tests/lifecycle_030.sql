\set ON_ERROR_STOP on
SELECT splitjson.create_table('public.life_docs','[["n"]]');
INSERT INTO life_docs VALUES(1,'{"n":1,"cold":"x"}');
SELECT splitjson.prepare_online_migration('life_docs','public.life_target','[["n"]]','{}') AS job \gset
SELECT cap_ok((splitjson.migration_status(:job)->>'state')='prepare');
SELECT cap_fails(format('SELECT splitjson.complete_migration(%s,''0/1'',false)',:job),'55000');
SELECT cap_fails(format('SELECT splitjson.mark_migration_state(%s,''copying'',''0/1'')',:job),'55000');
SELECT cap_fails(format('SELECT splitjson.mark_migration_state(%s,''ready'',''0/3'')',:job),'55000');
SELECT splitjson.abort_migration(:job,'test abort');
SELECT cap_ok((splitjson.migration_status(:job)->>'state')='aborted');
SELECT cap_fails(format('SELECT splitjson.mark_migration_state(%s,''ready'',''0/4'')',:job),'55000');
SELECT splitjson.create_table('public.rep_source','[["n"]]');
SELECT splitjson.create_table('public.rep_target','[["n"]]');
SELECT cap_ok((splitjson.prepare_replica('rep_source','rep_target')->>'state')='prepared');
SELECT cap_ok((splitjson.replication_status('rep_target')->>'state')='prepared');
SELECT cap_fails($q$SELECT splitjson.takeover_replica('rep_target','0/5',false)$q$,'55000');
SELECT 'online lifecycle precondition and replication manifest assertions passed';
