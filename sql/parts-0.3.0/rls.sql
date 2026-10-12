CREATE FUNCTION splitjson.enable_rls(p_table regclass,p_enabled boolean DEFAULT true,p_force boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    IF p_enabled IS NULL OR p_force IS NULL THEN RAISE EXCEPTION 'RLS flags must not be NULL' USING ERRCODE='22023'; END IF;
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    EXECUTE format('ALTER TABLE %s %s ROW LEVEL SECURITY',m.storage_name,CASE WHEN p_enabled THEN 'ENABLE' ELSE 'DISABLE' END);
    EXECUTE format('ALTER TABLE %s %s FORCE ROW LEVEL SECURITY',m.storage_name,CASE WHEN p_force THEN '' ELSE 'NO' END);
    EXECUTE format('ALTER VIEW %s SET (security_invoker=%s)',m.view_name,CASE WHEN p_enabled THEN 'true' ELSE 'false' END);
    UPDATE splitjson._tables SET rls_enabled=p_enabled,rls_force=p_force,
        view_definition=splitjson._view_definition(p_table) WHERE view_name=m.view_name;
END $$;

CREATE FUNCTION splitjson.set_policy(p_table regclass,p_name text,p_command text,p_roles name[],p_using text DEFAULT NULL,p_check text DEFAULT NULL,p_restrictive boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; role_sql text; r name; u text; c text;
BEGIN
    IF p_name IS NULL OR p_name='' OR octet_length(p_name)>63 OR p_command IS NULL OR p_command NOT IN ('select','insert','update','delete','all') OR
       p_roles IS NULL OR cardinality(p_roles)=0 OR p_restrictive IS NULL OR array_position(p_roles,NULL) IS NOT NULL OR
       (p_command='insert' AND p_using IS NOT NULL) OR (p_command IN ('select','delete') AND p_check IS NOT NULL) THEN
        RAISE EXCEPTION 'invalid policy declaration' USING ERRCODE='22023'; END IF;
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    FOREACH r IN ARRAY p_roles LOOP
        IF lower(r::text)<>'public' AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN
            RAISE EXCEPTION 'policy role does not exist' USING ERRCODE='42704'; END IF;
    END LOOP;
    u:=splitjson._policy_compile(p_table,m.storage_name::regclass,m.paths,p_using);
    c:=splitjson._policy_compile(p_table,m.storage_name::regclass,m.paths,p_check);
    SELECT string_agg(quote_ident(x.r),',') INTO role_sql FROM unnest(p_roles) x(r);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %s',p_name,m.storage_name);
    EXECUTE format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s',p_name,m.storage_name,
        CASE WHEN p_restrictive THEN 'RESTRICTIVE' ELSE 'PERMISSIVE' END,upper(p_command),role_sql,
        CASE WHEN u IS NULL THEN '' ELSE ' USING ('||u||')' END,CASE WHEN c IS NULL THEN '' ELSE ' WITH CHECK ('||c||')' END);
    INSERT INTO splitjson._policies VALUES(m.view_name,p_name,p_command,p_roles,p_using,p_check,p_restrictive)
        ON CONFLICT(view_name,policy_name) DO UPDATE SET command=EXCLUDED.command,roles=EXCLUDED.roles,using_expression=EXCLUDED.using_expression,check_expression=EXCLUDED.check_expression,restrictive=EXCLUDED.restrictive;
    UPDATE splitjson._tables SET policy_definition=splitjson._policy_definition(m.storage_name::regclass) WHERE view_name=m.view_name;
END $$;

CREATE FUNCTION splitjson.drop_policy(p_table regclass,p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    IF p_name IS NULL THEN RAISE EXCEPTION 'policy name must not be NULL' USING ERRCODE='22023'; END IF;
    EXECUTE format('DROP POLICY %I ON %s',p_name,m.storage_name);
    DELETE FROM splitjson._policies WHERE view_name=m.view_name AND policy_name=p_name;
    UPDATE splitjson._tables SET policy_definition=splitjson._policy_definition(m.storage_name::regclass) WHERE view_name=m.view_name;
END $$;
