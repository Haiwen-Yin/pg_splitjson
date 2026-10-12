\set ON_ERROR_STOP on
SET client_min_messages=warning;
CREATE EXTENSION pg_splitjson;
CREATE FUNCTION public.cap_ok(p boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
    IF p IS DISTINCT FROM true THEN RAISE EXCEPTION '0.3.0 assertion failed'; END IF;
END $$;
CREATE FUNCTION public.cap_fails(q text,s text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
    BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE=s THEN RETURN; END IF;
        RAISE EXCEPTION 'expected %, got %: %',s,SQLSTATE,SQLERRM;
    END;
    RAISE EXCEPTION 'expected error % for %',s,q;
END $$;
SELECT splitjson.create_table('public.cap_docs','[["state"],["counter"],["items",0,"name"]]','{"tenant":"name"}');
INSERT INTO cap_docs VALUES (1,'{"state":"new","counter":1,"items":[{"name":"a"}],"cold":{"x":1}}','cap_a'),
    (2,'{"state":"other","counter":0,"bad":"not-an-integer"}','cap_b');
CREATE TEMP TABLE tokens AS SELECT splitjson.row_revision('cap_docs',1) token;
DO $$ DECLARE t text; t2 text; BEGIN
    SELECT token INTO t FROM tokens;
    PERFORM cap_ok(t IS NOT NULL);
    t2:=splitjson.set_fields_if_revision('cap_docs',1,t,'[{"path":["state"],"value":"ready"}]');
    PERFORM cap_ok(t2 IS NOT NULL AND t2<>t);
    PERFORM cap_fails(format('SELECT splitjson.set_fields_if_revision(''cap_docs'',1,%L,''[{"path":["counter"],"value":9}]'')',t),'40001');
    PERFORM cap_ok(splitjson.get_field('cap_docs',1,ARRAY['counter'])='1');
    t:=splitjson.apply_patch('cap_docs',1,'[]'); PERFORM cap_ok(t=t2);
    t:=splitjson.apply_patch('cap_docs',1,'[{"op":"test","path":"/counter","value":1}]'); PERFORM cap_ok(t=t2);
    PERFORM splitjson.apply_patch('cap_docs',1,'[{"op":"replace","path":"/state","value":"patched"},{"op":"add","path":"/a~1b","value":1},{"op":"copy","from":"/state","path":"/copied"}]');
    PERFORM cap_ok((SELECT doc->'a/b'='1' AND doc->'copied'='"patched"' FROM cap_docs WHERE id=1));
    PERFORM splitjson.merge_patch('cap_docs',1,'{"copied":null,"nested":{"v":1}}');
    PERFORM cap_ok((SELECT NOT doc ? 'copied' AND doc->'nested'='{"v":1}' FROM cap_docs WHERE id=1));
    PERFORM cap_fails($q$SELECT splitjson.apply_patch('cap_docs',1,'[{"op":"remove","path":""}]')$q$,'0A000');
    PERFORM cap_fails($q$SELECT splitjson.apply_patch('cap_docs',1,'[{"op":"test","path":"/missing","value":null}]')$q$,'40001');
    PERFORM cap_fails($q$SELECT splitjson.apply_patch('cap_docs',1,'[{"op":"add","path":"/items/00","value":1}]')$q$,'22023');
    PERFORM cap_fails($q$SELECT splitjson.apply_patch('cap_docs',1,'[{"op":"add","path":"/items/-1","value":1}]')$q$,'22023');
    PERFORM cap_fails($q$SELECT splitjson.apply_patch('cap_docs',1,'[{"op":"move","from":"/nested","path":"/nested/child"}]')$q$,'22023');
    PERFORM splitjson.upsert_document('cap_docs',3,'{"state":"inserted","counter":0}','{"tenant":"cap_b"}');
    PERFORM splitjson.upsert_document('cap_docs',3,'{"state":"updated","counter":1}');
    PERFORM cap_ok((SELECT tenant='cap_b' AND doc->'state'='"updated"' FROM cap_docs WHERE id=3));
END $$;
CREATE ROLE cap_a;
CREATE ROLE cap_b;
SELECT splitjson.grant_access('cap_docs','cap_a','write');
SELECT splitjson.grant_access('cap_docs','cap_b','write');
SELECT splitjson.enable_rls('cap_docs');
SET ROLE cap_a;
SELECT cap_ok((SELECT count(*)=0 FROM cap_docs));
SELECT cap_ok(splitjson.get_field('cap_docs',1,ARRAY['state']) IS NULL);
SELECT cap_ok(splitjson.row_revision('cap_docs',1) IS NULL);
SELECT cap_ok(NOT splitjson.set_field('cap_docs',1,ARRAY['state'],'"blocked"'));
SELECT cap_fails($q$INSERT INTO cap_docs VALUES(4,'{}','cap_a')$q$,'42501');
RESET ROLE;
SELECT splitjson.set_policy('cap_docs','tenant_access','all',ARRAY['cap_a','cap_b'],
    'tenant=current_user','tenant=current_user',false);
SELECT splitjson.set_policy('cap_docs','safe_state','all',ARRAY['public'],
    'splitjson.policy_field(''["state"]''::jsonb) <> ''"blocked"''::jsonb',
    'splitjson.policy_field(''["state"]''::jsonb) <> ''"blocked"''::jsonb',true);
SELECT cap_fails($q$SELECT splitjson.set_policy('cap_docs','unsafe','all',ARRAY['public'],'doc IS NOT NULL')$q$,'0A000');
SELECT cap_fails($q$SELECT splitjson.set_policy('cap_docs','unsafe','all',ARRAY['public'],'exists(select 1)')$q$,'0A000');
SELECT cap_fails($q$SELECT splitjson.set_policy('cap_docs','unsafe','all',ARRAY['public'],'current_setting(''role'')=''cap_a''')$q$,'0A000');
SET ROLE cap_a;
SELECT cap_ok((SELECT count(*)=1 FROM cap_docs));
COPY cap_docs(id,doc,tenant) FROM STDIN;
5	{"state":"copied","counter":5}	cap_a
\.
SELECT cap_ok((SELECT doc->>'state'='copied' FROM cap_docs WHERE id=5));
DELETE FROM cap_docs WHERE id=5;
SELECT cap_ok((SELECT array_agg(id)=ARRAY[1::bigint] FROM splitjson.find_ids('cap_docs',ARRAY['counter'],'1') x(id)));
SELECT cap_ok(splitjson.get_field('cap_docs',2,ARRAY['state']) IS NULL);
SELECT cap_ok(splitjson.row_revision('cap_docs',2) IS NULL);
SELECT cap_ok(NOT splitjson.set_fields('cap_docs',2,'[{"path":["state"],"value":"blocked"}]'));
SELECT cap_ok(splitjson.increment_field('cap_docs',2,ARRAY['counter']) IS NULL);
SELECT cap_ok(NOT splitjson.delete_field('cap_docs',2,ARRAY['counter']));
SELECT cap_ok(splitjson.apply_patch('cap_docs',2,'[]') IS NULL);
SELECT cap_ok(splitjson.merge_patch('cap_docs',2,'{}') IS NULL);
SELECT cap_fails($q$SELECT splitjson.set_field('cap_docs',1,ARRAY['state'],'"blocked"')$q$,'42501');
SELECT cap_fails($q$SELECT splitjson.apply_patch('cap_docs',1,'[{"op":"replace","path":"/state","value":"blocked"}]')$q$,'42501');
SELECT cap_fails($q$UPDATE cap_docs SET tenant='cap_b' WHERE id=1$q$,'42501');
SELECT cap_fails($q$SELECT splitjson.upsert_document('cap_docs',1,'{"state":"okay"}','{"tenant":"cap_b"}')$q$,'42501');
SELECT cap_fails($q$SELECT splitjson.upsert_document('cap_docs',2,'{"state":"okay"}','{"tenant":"cap_a"}')$q$,'42501');
INSERT INTO cap_docs VALUES(4,'{"state":"okay","counter":5}','cap_a');
SELECT cap_ok(splitjson.increment_field('cap_docs',4,ARRAY['counter'])=6);
SELECT cap_ok(splitjson.set_field('cap_docs',4,ARRAY['state'],'"good"'));
SELECT cap_ok(splitjson.get_field('cap_docs',4,ARRAY['counter'])='6');
SELECT cap_fails($q$SELECT * FROM splitjson_storage.s_1$q$,'42501');
SELECT cap_fails($q$SELECT * FROM splitjson._tables$q$,'42501');
SELECT cap_fails($q$SELECT splitjson._api_get_field('cap_docs',1,ARRAY['state'])$q$,'42501');
PREPARE cap_select AS SELECT array_agg(id ORDER BY id) FROM cap_docs;
EXECUTE cap_select;
SELECT cap_ok((SELECT count(*)=2 FROM cap_docs WHERE (doc->>'bad')::integer IS NULL));
RESET ROLE;
SET ROLE cap_b;
EXECUTE cap_select;
SELECT cap_ok((SELECT array_agg(id ORDER BY id)=ARRAY[2::bigint,3] FROM cap_docs));
SELECT cap_ok(splitjson.get_field('cap_docs',1,ARRAY['state']) IS NULL);
SET row_security=off;
SELECT cap_fails('SELECT * FROM cap_docs','42501');
SELECT cap_fails($q$SELECT splitjson.get_field('cap_docs',2,ARRAY['state'])$q$,'42501');
RESET row_security;
RESET ROLE;
SELECT cap_fails('DROP POLICY tenant_access ON splitjson_storage.s_1','55000');
SELECT cap_fails('ALTER TABLE splitjson_storage.s_1 FORCE ROW LEVEL SECURITY','55000');
SELECT splitjson.create_partitioned_table('public.cap_part','[["state"]]','{}','{"strategy":"hash","modulus":2}');
INSERT INTO cap_part VALUES(1,'{"state":"a"}'),(2,'{"state":"b"}');
SELECT cap_ok((SELECT count(*)=2 FROM cap_part));
SELECT cap_ok((SELECT count(*)=2 FROM splitjson.export_rows('cap_part')));
SELECT cap_ok((splitjson.replication_manifest('cap_part')->>'same_layout_only')::boolean);
SELECT splitjson.create_path_index('cap_part','cap_part_state_idx',ARRAY['state']);
SELECT cap_ok((splitjson.check_all(true) IS NOT NULL));
SELECT '0.3.0 capability assertions passed';
