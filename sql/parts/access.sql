-- New-install and supported upgrade registration. Use canonical descriptors for
-- pg_dump round trips; OIDs are never stored in the dumped configuration table.
UPDATE splitjson._tables SET view_definition=splitjson._view_definition(to_regclass(view_name)),
    storage_definition=splitjson._storage_definition(to_regclass(storage_name));
ALTER TABLE splitjson._tables ALTER COLUMN view_definition SET NOT NULL;
ALTER TABLE splitjson._tables ALTER COLUMN storage_definition SET NOT NULL;
DO $$ DECLARE meta splitjson._tables%ROWTYPE; BEGIN
    FOR meta IN SELECT * FROM splitjson._tables LOOP PERFORM splitjson._validate_mapping(meta); END LOOP;
END $$;

CREATE EVENT TRIGGER splitjson_ddl_start ON ddl_command_start
    EXECUTE FUNCTION splitjson._ddl_start_guard();
CREATE EVENT TRIGGER splitjson_ddl_end ON ddl_command_end
    EXECUTE FUNCTION splitjson._ddl_end_guard();
CREATE EVENT TRIGGER splitjson_sql_drop ON sql_drop
    EXECUTE FUNCTION splitjson._sql_drop_guard();

CREATE OR REPLACE FUNCTION splitjson.grant_access(p_table regclass,p_role regrole,p_mode text)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE meta splitjson._tables%ROWTYPE; role_name name;
BEGIN
    meta := splitjson._lookup(p_table,'SELECT');
    SELECT rolname INTO role_name FROM pg_roles WHERE oid=p_role;
    IF role_name IS NULL OR p_mode IS NULL OR p_mode NOT IN ('read','write') THEN
        RAISE EXCEPTION 'use an existing role and mode read or write' USING ERRCODE='22023';
    END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA splitjson,%I TO %I',
                   (parse_ident(meta.view_name,true))[1],role_name);
    EXECUTE format('GRANT SELECT ON %s TO %I',meta.view_name,role_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION splitjson.get_field(regclass,bigint,text[]),'
                   'splitjson.find_ids(regclass,text[],jsonb) TO %I',role_name);
    IF p_mode='write' THEN
        EXECUTE format('GRANT INSERT,UPDATE,DELETE ON %s TO %I',meta.view_name,role_name);
        EXECUTE format('GRANT EXECUTE ON FUNCTION splitjson.set_field(regclass,bigint,text[],jsonb,boolean),'
            'splitjson.set_fields(regclass,bigint,jsonb,boolean),splitjson.delete_field(regclass,bigint,text[]),'
            'splitjson.increment_field(regclass,bigint,text[],numeric) TO %I',role_name);
    END IF;
END $$;

-- Scope ACL changes to this extension, not unrelated functions in the schema.
DO $$ DECLARE signature text; grantee_name text; BEGIN
    FOR signature,grantee_name IN SELECT p.oid::regprocedure::text,
        CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee JOIN pg_depend d
        ON d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e'
        JOIN pg_extension e ON d.refclassid='pg_extension'::regclass AND d.refobjid=e.oid
        WHERE e.extname='pg_splitjson' AND a.grantee<>p.proowner
    LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s CASCADE',signature,grantee_name); END LOOP;
    PERFORM splitjson._secure_relation('splitjson._tables');
    PERFORM splitjson._secure_relation('splitjson._table_id_seq');
END $$;
DO $$ DECLARE relation text; grantee_name text; BEGIN
    FOR relation IN SELECT storage_name FROM splitjson._tables LOOP
        PERFORM splitjson._secure_relation(relation::regclass);
    END LOOP;
    FOR grantee_name IN SELECT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE n.oid='splitjson_storage'::regnamespace AND a.grantee<>n.nspowner
    LOOP EXECUTE format('REVOKE ALL ON SCHEMA splitjson_storage FROM %s CASCADE',grantee_name); END LOOP;
END $$;
-- Views execute these pure functions as the querying role; no private access.
GRANT EXECUTE ON FUNCTION splitjson.cold_in(cstring),splitjson.cold_out(splitjson.cold),
    splitjson.cold_send(splitjson.cold),splitjson.cold_recv(internal),
    splitjson.restore(splitjson.cold,jsonb[]),splitjson.restore(splitjson.cold,jsonb[],jsonb) TO PUBLIC;

COMMENT ON EXTENSION pg_splitjson IS 'PostgreSQL Split JSON Storage Extension';
COMMENT ON FUNCTION splitjson.grant_access(regclass,regrole,text) IS 'Installer grants view privileges and minimal read/write API execution; never private storage';
COMMENT ON FUNCTION splitjson.index_ddl(regclass,text,jsonb,text,boolean) IS 'Return reviewed concurrent index DDL; execute separately outside a transaction';
COMMENT ON TYPE splitjson.cold IS 'Version 2 cold envelope (reads v1); PG18 physical format, logical migration across major versions';
