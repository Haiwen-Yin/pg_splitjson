-- pg_splitjson 0.3.0 additions.  This file is appended to the frozen 0.2.0
-- install body and is also the 0.2.0 -> 0.3.0 upgrade body.
-- Copyright 2026 PG SplitJSON contributors
-- SPDX-License-Identifier: Apache-2.0

CREATE FUNCTION splitjson._storage_write_guard() RETURNS trigger
AS 'MODULE_PATHNAME','pg_splitjson_storage_write_guard' LANGUAGE C SECURITY DEFINER SET search_path=pg_catalog,pg_temp;

ALTER EVENT TRIGGER splitjson_ddl_end DISABLE;
ALTER EVENT TRIGGER splitjson_sql_drop DISABLE;

ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS layout_epoch text;
ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS storage_mode text NOT NULL DEFAULT 'heap';
ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS partition_spec jsonb;
ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS rls_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS rls_force boolean NOT NULL DEFAULT false;
ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS layout_generation bigint NOT NULL DEFAULT 1;
ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS follower_mode boolean NOT NULL DEFAULT false;
ALTER TABLE splitjson._tables ADD COLUMN IF NOT EXISTS revision_sequence text;
ALTER TABLE splitjson._tables ADD COLUMN write_fenced boolean NOT NULL DEFAULT false;
ALTER TABLE splitjson._tables ADD COLUMN fence_lsn pg_lsn;
ALTER TABLE splitjson._tables ADD COLUMN revision_initialized boolean NOT NULL DEFAULT false;
ALTER TABLE splitjson._tables ADD COLUMN policy_definition jsonb NOT NULL DEFAULT '[]';
CREATE TABLE splitjson._leaves (
    view_name text NOT NULL REFERENCES splitjson._tables(view_name) ON DELETE CASCADE ON UPDATE CASCADE,
    relation_name text PRIMARY KEY,bound text NOT NULL,bound_spec jsonb);
SELECT pg_extension_config_dump('splitjson._leaves','');
CREATE TABLE splitjson._path_indexes (
    view_name text NOT NULL REFERENCES splitjson._tables(view_name) ON DELETE CASCADE ON UPDATE CASCADE,
    index_name text PRIMARY KEY,path jsonb NOT NULL,kind text NOT NULL,collation_name text,
    expression text NOT NULL,guard_name text,definition text);
SELECT pg_extension_config_dump('splitjson._path_indexes','');
ALTER TABLE splitjson._tables ADD CONSTRAINT splitjson_storage_mode_ck
    CHECK (storage_mode IN ('heap','hash','range'));

CREATE TABLE splitjson._policies (view_name text NOT NULL REFERENCES splitjson._tables(view_name) ON DELETE CASCADE ON UPDATE CASCADE,
    policy_name text NOT NULL,command text NOT NULL,roles name[] NOT NULL,using_expression text,check_expression text,restrictive boolean NOT NULL,PRIMARY KEY(view_name,policy_name));
SELECT pg_extension_config_dump('splitjson._policies','');
CREATE TABLE splitjson._field_checks (view_name text NOT NULL REFERENCES splitjson._tables(view_name) ON DELETE CASCADE ON UPDATE CASCADE,
    constraint_name text NOT NULL,path jsonb NOT NULL,json_type text NOT NULL,required boolean NOT NULL,PRIMARY KEY(view_name,constraint_name));
SELECT pg_extension_config_dump('splitjson._field_checks','');
CREATE TABLE splitjson._slot_types (view_name text NOT NULL REFERENCES splitjson._tables(view_name) ON DELETE CASCADE ON UPDATE CASCADE,path jsonb NOT NULL,kind text NOT NULL,guard_name text NOT NULL,definition text NOT NULL,PRIMARY KEY(view_name,path));
SELECT pg_extension_config_dump('splitjson._slot_types','');
CREATE SEQUENCE splitjson._job_id_seq NO CYCLE;
SELECT pg_extension_config_dump('splitjson._job_id_seq','');
CREATE TABLE splitjson._jobs (
    id bigint PRIMARY KEY DEFAULT nextval('splitjson._job_id_seq'),source_name text NOT NULL,target_name text NOT NULL,
    state text NOT NULL,source_epoch text NOT NULL,target_epoch text,source_fingerprint text NOT NULL,slot_name name UNIQUE,
    start_lsn pg_lsn,confirmed_lsn pg_lsn,ready_lsn pg_lsn,error_state text,detail jsonb NOT NULL DEFAULT '{}');
SELECT pg_extension_config_dump('splitjson._jobs','');
CREATE TABLE splitjson._migration_rows(job_id bigint NOT NULL REFERENCES splitjson._jobs(id) ON DELETE CASCADE,id bigint NOT NULL,columns jsonb NOT NULL,PRIMARY KEY(job_id,id));
SELECT pg_extension_config_dump('splitjson._migration_rows','');
CREATE TABLE splitjson._replicas (
    view_name text PRIMARY KEY,source_view text,publication_name name,subscription_name name,state text NOT NULL,
    fingerprint text NOT NULL,final_lsn pg_lsn,detail jsonb NOT NULL DEFAULT '{}');
SELECT pg_extension_config_dump('splitjson._replicas','');

CREATE OR REPLACE FUNCTION splitjson._new_epoch() RETURNS text
LANGUAGE sql VOLATILE SET search_path=pg_catalog, pg_temp
RETURN gen_random_uuid()::text;

UPDATE splitjson._tables SET layout_epoch=splitjson._new_epoch() WHERE layout_epoch IS NULL;
ALTER TABLE splitjson._tables ALTER COLUMN layout_epoch SET NOT NULL;
ALTER TABLE splitjson._tables ALTER COLUMN layout_epoch SET DEFAULT splitjson._new_epoch();

CREATE OR REPLACE FUNCTION splitjson._revision_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    -- Native logical replication applies the publisher's physical revision;
    -- never allocate a new local revision or alter the source token.
    IF current_setting('session_replication_role',true)='replica' THEN RETURN NEW; END IF;
    -- Native cross-partition UPDATE has already assigned its revision in the
    -- old leaf. All business INSERTs omit this hidden column and start at 0.
    IF TG_OP='INSERT' AND NEW.row_revision>0 THEN RETURN NEW; END IF;
    SELECT * INTO STRICT m FROM splitjson._tables WHERE to_regclass(storage_name)=TG_RELID
        OR to_regclass(storage_name) IN (SELECT pg_partition_ancestors(TG_RELID));
    IF NOT m.revision_initialized THEN
        PERFORM pg_advisory_xact_lock(hashtext('pg_splitjson_revision'),hashtext(m.storage_name));
        IF to_regclass(m.revision_sequence) IS NULL THEN
            EXECUTE format('CREATE SEQUENCE %s NO CYCLE',m.revision_sequence);
            PERFORM splitjson._secure_relation(m.revision_sequence::regclass);
        END IF;
        UPDATE splitjson._tables SET revision_initialized=true WHERE view_name=m.view_name;
    END IF;
    NEW.row_revision:=nextval(m.revision_sequence::regclass);
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION splitjson._revision_write() FROM PUBLIC;

DO $$
DECLARE m splitjson._tables%ROWTYPE; trigger_name text;
BEGIN
    FOR m IN SELECT * FROM splitjson._tables LOOP
        IF m.revision_sequence IS NULL THEN
            m.revision_sequence:=format('splitjson._revision_%s',md5(m.storage_name));
            -- Lazy first-write creation keeps per-relation sequences ordinary
            -- dumpable objects, rather than undumpable upgrade-only members.
            UPDATE splitjson._tables SET revision_sequence=m.revision_sequence WHERE view_name=m.view_name;
        END IF;
        EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS row_revision bigint NOT NULL DEFAULT 0', m.storage_name);
        EXECUTE format('ALTER TABLE %s ALTER COLUMN cold SET STORAGE EXTERNAL', m.storage_name);
        trigger_name := format('pg_splitjson_revision_%s', md5(m.storage_name));
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=m.storage_name::regclass AND tgname=trigger_name) THEN
            EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION splitjson._revision_write()', trigger_name,m.storage_name);
        END IF;
        EXECUTE format('CREATE TRIGGER pg_splitjson_fence BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION splitjson._storage_write_guard()',m.storage_name);
        UPDATE splitjson._tables SET storage_definition=splitjson._storage_definition(m.storage_name::regclass)
            WHERE view_name=m.view_name;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION splitjson._metadata_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
BEGIN
    NEW.revision_sequence:=format('splitjson._revision_%s',md5(NEW.storage_name));
    EXECUTE format('CREATE SEQUENCE %s NO CYCLE',NEW.revision_sequence);
    PERFORM splitjson._secure_relation(NEW.revision_sequence::regclass);
    EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS row_revision bigint NOT NULL DEFAULT 0',NEW.storage_name);
    EXECUTE format('ALTER TABLE %s ALTER COLUMN cold SET STORAGE EXTERNAL',NEW.storage_name);
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=NEW.storage_name::regclass AND tgname=format('pg_splitjson_revision_%s',md5(NEW.storage_name))) THEN
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION splitjson._revision_write()',format('pg_splitjson_revision_%s',md5(NEW.storage_name)),NEW.storage_name);
    END IF;
    NEW.revision_initialized:=true;
    EXECUTE format('CREATE TRIGGER pg_splitjson_fence BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION splitjson._storage_write_guard()',NEW.storage_name);
    NEW.storage_definition:=splitjson._storage_definition(NEW.storage_name::regclass);
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS splitjson_metadata_insert ON splitjson._tables;
CREATE TRIGGER splitjson_metadata_insert BEFORE INSERT ON splitjson._tables FOR EACH ROW EXECUTE FUNCTION splitjson._metadata_insert();
REVOKE ALL ON FUNCTION splitjson._metadata_insert() FROM PUBLIC;

CREATE OR REPLACE FUNCTION splitjson._token(p_epoch text,p_id bigint,p_revision bigint) RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
RETURN p_epoch || ':' || p_id::text || ':' || p_revision::text;

CREATE OR REPLACE FUNCTION splitjson._token_revision(p_token text,p_epoch text,p_id bigint)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
AS $$
DECLARE parts text[]; result bigint;
BEGIN
    parts := string_to_array(p_token,':');
    IF cardinality(parts)<>3 OR parts[1]<>p_epoch OR parts[2]<>p_id::text OR parts[3] !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'stale or invalid revision token' USING ERRCODE='40001';
    END IF;
    result := parts[3]::bigint;
    RETURN result;
EXCEPTION WHEN numeric_value_out_of_range THEN
    RAISE EXCEPTION 'stale or invalid revision token' USING ERRCODE='40001';
END $$;

