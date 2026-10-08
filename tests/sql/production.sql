\set ECHO none
\set QUIET on
\set ON_ERROR_STOP on
SET client_min_messages=warning;
CREATE EXTENSION pg_splitjson;
LOAD 'pg_splitjson';
CREATE FUNCTION public.ok(p boolean) RETURNS void LANGUAGE plpgsql AS $$BEGIN
    IF p IS DISTINCT FROM true THEN RAISE EXCEPTION 'production assertion failed'; END IF;
END$$;
CREATE FUNCTION public.fails(q text,s text) RETURNS void LANGUAGE plpgsql AS $$BEGIN
    BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE=s THEN RETURN; END IF;
        RAISE EXCEPTION 'expected %, got %: %',s,SQLSTATE,SQLERRM;
    END;
    RAISE EXCEPTION 'expected error %',s;
END$$;
DO $$ BEGIN
    PERFORM ok((SELECT extversion='0.2.0' FROM pg_extension WHERE extname='pg_splitjson'));
    PERFORM splitjson.create_table('public.prod_docs','[["n"],["state"],["items",0,"n"]]',
                                  '{"tenant":"bigint","label":"varchar(12)"}');
END$$;
CREATE ROLE splitjson_020_reader;
CREATE ROLE splitjson_020_writer;
CREATE ROLE splitjson_020_denied;
DO $$ BEGIN
    PERFORM splitjson.grant_access('prod_docs','splitjson_020_reader','read');
    PERFORM splitjson.grant_access('prod_docs','splitjson_020_writer','write');
    PERFORM splitjson.set_business_default('prod_docs','tenant','7');
    PERFORM splitjson.set_business_not_null('prod_docs','tenant');
END$$;
INSERT INTO prod_docs(id,doc,label) VALUES(1,'{"n":1,"state":"new","items":[{"n":1}],"cold":"stable"}','a'),
                                           (2,'{"n":2,"state":"ready"}','b');
DO $$ BEGIN
    PERFORM ok((SELECT tenant=7 FROM prod_docs WHERE id=1));
    PERFORM splitjson.add_field_check('prod_docs','n_number','["n"]','number',true);
    PERFORM fails($q$SELECT splitjson.set_field('prod_docs',1,ARRAY['n'],'"bad"')$q$,'23514');
    PERFORM fails($q$SELECT splitjson.delete_field('prod_docs',1,ARRAY['n'])$q$,'23514');
    PERFORM fails($q$UPDATE prod_docs SET tenant=NULL WHERE id=1$q$,'23502');
    PERFORM ok((splitjson.check_table('prod_docs',true)->>'rows_checked')::integer=2);
    PERFORM ok(splitjson.table_stats('prod_docs')->>'view'='public.prod_docs');
    PERFORM ok(splitjson.index_ddl('prod_docs','prod_state_idx','["state"]','text') LIKE 'CREATE INDEX CONCURRENTLY%');
END$$;
SET ROLE splitjson_020_reader;
DO $$ BEGIN
    PERFORM ok(splitjson.get_field('prod_docs',1,ARRAY['n'])='1');
    PERFORM ok((SELECT count(*)=1 FROM splitjson.find_ids('prod_docs',ARRAY['state'],'"new"')));
    PERFORM fails($q$SELECT splitjson.set_field('prod_docs',1,ARRAY['n'],'9')$q$,'42501');
    PERFORM fails($q$SELECT * FROM splitjson._tables$q$,'42501');
    PERFORM fails($q$SELECT splitjson.storage_relation('prod_docs')$q$,'42501');
    PERFORM fails($q$SELECT splitjson.grant_access('prod_docs','splitjson_020_reader','write')$q$,'42501');
END$$;
RESET ROLE;
SET ROLE splitjson_020_writer;
DO $$ BEGIN
    PERFORM ok(splitjson.increment_field('prod_docs',1,ARRAY['n'])=2);
    PERFORM splitjson.set_fields('prod_docs',1,'[{"path":["state"],"value":"done"},{"path":["items","0","n"],"value":3}]');
    PERFORM ok((SELECT doc->>'state'='done' FROM prod_docs WHERE id=1));
    PERFORM fails($q$SELECT splitjson.create_table('public.denied','[["n"]]')$q$,'42501');
END$$;
RESET ROLE;
SET ROLE splitjson_020_denied;
DO $$ BEGIN
    PERFORM fails($q$SELECT splitjson.get_field('prod_docs',1,ARRAY['n'])$q$,'42501');
    PERFORM fails($q$SELECT splitjson.pack('{}','[]')$q$,'42501');
END$$;
RESET ROLE;
DO $$ DECLARE store regclass; BEGIN
    store:=splitjson.storage_relation('prod_docs');
    PERFORM fails('ALTER VIEW prod_docs RENAME TO drift','55000');
    PERFORM fails('DROP VIEW prod_docs','55000');
    PERFORM fails(format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',store),'55000');
    PERFORM fails(format('ALTER TABLE %s RENAME COLUMN hot_1 TO drift',store),'55000');
    PERFORM fails('ALTER TABLE prod_docs DISABLE TRIGGER pg_splitjson_write','42809');
    PERFORM fails('DROP TRIGGER pg_splitjson_write ON prod_docs','55000');
    PERFORM fails('DROP EXTENSION pg_splitjson CASCADE','55000');
    PERFORM fails('DROP SCHEMA splitjson CASCADE','55000');
    PERFORM splitjson.rename_table('prod_docs','public.renamed_prod_docs');
    PERFORM ok(splitjson.get_field('renamed_prod_docs',1,ARRAY['n'])='2');
    PERFORM ok((splitjson.check_table('renamed_prod_docs',true)->>'rows_checked')::integer=2);
END$$;
DO $$ BEGIN
    PERFORM splitjson.drop_table('renamed_prod_docs');
END$$;
DROP OWNED BY splitjson_020_reader,splitjson_020_writer,splitjson_020_denied;
DROP ROLE splitjson_020_reader,splitjson_020_writer,splitjson_020_denied;
DROP FUNCTION public.ok(boolean),public.fails(text,text);
DROP EXTENSION pg_splitjson;
\pset format unaligned
\t on
\set QUIET off
SELECT 'production installcheck passed' AS result;
