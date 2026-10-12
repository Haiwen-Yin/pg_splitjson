\set ON_ERROR_STOP on
CREATE DOMAIN public.cap_domain AS numeric(12,3) CHECK(VALUE>=0);
SELECT splitjson.create_table('public.portable_docs','[["n"],["items",0,"name"]]','{"amount":"public.cap_domain","dims":"integer[]","label":"varchar(8)"}');
INSERT INTO portable_docs VALUES(1,'{"n":1,"items":[{"name":"a"}],"cold":null}',1.230,'[0:1]={7,8}','label'),(2,'null',NULL,NULL,NULL);
SELECT splitjson.set_business_default('portable_docs','label','"default"');
SELECT splitjson.add_field_check('portable_docs','portable_n','["n"]','number',false);
SELECT splitjson.create_path_index('portable_docs','portable_n_idx',ARRAY['n'],'numeric');
SELECT splitjson.set_business_collation('portable_docs','label','C');
SELECT splitjson.migrate_layout('portable_docs','public.portable_copy','[["n"],["items",0,"name"],["cold"]]', '{"copy":["defaults","checks","collation"],"ignore_manual":true}');
SELECT cap_ok(NOT EXISTS((SELECT * FROM portable_docs EXCEPT SELECT * FROM portable_copy) UNION ALL (SELECT * FROM portable_copy EXCEPT SELECT * FROM portable_docs)));
SELECT cap_ok((SELECT array_dims(dims)='[0:1]' AND amount=1.230 FROM portable_copy WHERE id=1));
SELECT cap_ok((SELECT attcollation='"C"'::regcollation FROM pg_attribute WHERE attrelid='portable_copy'::regclass AND attname='label'));
SELECT splitjson.migrate_layout('portable_docs','public.portable_default','[["n"]]', '{"copy":["defaults","checks","indexes","collation"],"ignore_manual":true}');
INSERT INTO portable_default(id,doc,amount,dims) VALUES(3,'{"n":3}',2.100,'[3:3]={9}');
SELECT cap_ok((SELECT label='default' FROM portable_default WHERE id=3));
SELECT cap_ok((SELECT count(*)=2 FROM splitjson.export_rows('portable_docs')));
SELECT cap_fails($q$SELECT splitjson.import_manifest('{"format":2}', 'public.invalid_import')$q$,'22023');
-- Explicit subset is supported without borrowing the installer's policy role.
GRANT CREATE ON SCHEMA public TO cap_a;
GRANT EXECUTE ON FUNCTION splitjson.migrate_layout(regclass,text,jsonb,jsonb),splitjson.export_manifest(regclass,boolean,jsonb),splitjson.export_rows(regclass,boolean) TO cap_a;
SET ROLE cap_a;
SELECT cap_fails($q$SELECT splitjson.export_manifest('cap_docs',false)$q$,'42501');
SELECT cap_ok((splitjson.export_manifest('cap_docs',true)->>'subset')::boolean);
SELECT cap_ok((SELECT count(*)=2 FROM splitjson.export_rows('cap_docs',true)));
SELECT splitjson.migrate_layout('cap_docs','public.subset_copy','[["state"]]','{"subset":true}');
RESET ROLE;
SELECT cap_ok((SELECT count(*)=2 FROM subset_copy));
SELECT cap_ok((SELECT count(*)=4 FROM cap_docs));
SELECT 'typed snapshot migration and declarative portability assertions passed';
