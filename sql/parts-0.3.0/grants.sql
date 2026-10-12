CREATE OR REPLACE FUNCTION splitjson.grant_access(p_table regclass,p_role regrole,p_mode text)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog, pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; role_name name;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table); SELECT rolname INTO role_name FROM pg_roles WHERE oid=p_role;
    IF role_name IS NULL OR p_mode IS NULL OR p_mode NOT IN ('read','write') THEN RAISE EXCEPTION 'use an existing role and mode read or write' USING ERRCODE='22023'; END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA splitjson,%I TO %I',(parse_ident(m.view_name,true))[1],role_name);
    EXECUTE format('GRANT SELECT ON %s TO %I',m.view_name,role_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION splitjson.get_field(regclass,bigint,text[]),splitjson.find_ids(regclass,text[],jsonb),splitjson.row_revision(regclass,bigint),splitjson.find_ids_range(regclass,text[],text,jsonb,jsonb,boolean,boolean,name) TO %I',role_name);
    IF p_mode='write' THEN
        EXECUTE format('GRANT INSERT,UPDATE,DELETE ON %s TO %I',m.view_name,role_name);
        EXECUTE format('GRANT EXECUTE ON FUNCTION splitjson.set_field(regclass,bigint,text[],jsonb,boolean),splitjson.set_fields(regclass,bigint,jsonb,boolean),splitjson.delete_field(regclass,bigint,text[]),splitjson.increment_field(regclass,bigint,text[],numeric),splitjson.set_fields_if_revision(regclass,bigint,text,jsonb,boolean),splitjson.apply_patch(regclass,bigint,jsonb,text),splitjson.merge_patch(regclass,bigint,jsonb,text),splitjson.upsert_document(regclass,bigint,jsonb,jsonb) TO %I',role_name);
    END IF;
END $$;

