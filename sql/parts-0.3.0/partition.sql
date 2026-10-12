-- Native partition routing, with id as the entire partition key.
CREATE FUNCTION splitjson._range_bound(p_bound jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp
AS $$
DECLARE lo text; hi text;
BEGIN
    IF jsonb_typeof(p_bound)<>'object' OR (SELECT count(*) FROM jsonb_object_keys(p_bound))<>2 OR
       NOT p_bound ? 'from' OR NOT p_bound ? 'to' THEN
        RAISE EXCEPTION 'range bounds require exactly from and to' USING ERRCODE='22023'; END IF;
    lo:=p_bound->>'from'; hi:=p_bound->>'to';
    IF (lo IS NOT NULL AND (jsonb_typeof(p_bound->'from')<>'number' OR lo !~ '^-?(0|[1-9][0-9]*)$')) OR
       (hi IS NOT NULL AND (jsonb_typeof(p_bound->'to')<>'number' OR hi !~ '^-?(0|[1-9][0-9]*)$')) THEN
        RAISE EXCEPTION 'range bounds must be bigint numbers or JSON null' USING ERRCODE='22023'; END IF;
    IF lo IS NOT NULL THEN lo:=lo::bigint::text; END IF;
    IF hi IS NOT NULL THEN hi:=hi::bigint::text; END IF;
    IF lo IS NOT NULL AND hi IS NOT NULL AND lo::bigint>=hi::bigint THEN
        RAISE EXCEPTION 'lower bound must precede upper bound' USING ERRCODE='22023'; END IF;
    RETURN format('FOR VALUES FROM (%s) TO (%s)',coalesce(lo,'MINVALUE'),coalesce(hi,'MAXVALUE'));
END $$;

CREATE FUNCTION splitjson._register_leaves(p_table regclass,p_storage regclass) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
    INSERT INTO splitjson._leaves(view_name,relation_name,bound,bound_spec)
        SELECT splitjson._qualified_name(p_table),splitjson._qualified_name(c.oid),pg_get_expr(c.relpartbound,c.oid),splitjson._partition_bound(c.oid)
        FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent=p_storage
        ON CONFLICT(relation_name) DO UPDATE SET bound=EXCLUDED.bound,bound_spec=EXCLUDED.bound_spec;
    UPDATE splitjson._tables SET partition_spec=(SELECT jsonb_agg(l.bound_spec ORDER BY (l.bound_spec->>'from')::bigint NULLS FIRST)
        FROM splitjson._leaves l WHERE l.view_name=splitjson._qualified_name(p_table)) WHERE view_name=splitjson._qualified_name(p_table) AND storage_mode='range';
END $$;

CREATE FUNCTION splitjson._assert_idle(p_table regclass) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM splitjson._jobs WHERE (source_name=splitjson._qualified_name(p_table) OR target_name=splitjson._qualified_name(p_table))
              AND state NOT IN ('aborted','completed')) OR
       EXISTS(SELECT 1 FROM splitjson._replicas WHERE view_name=splitjson._qualified_name(p_table) AND state NOT IN ('detached','promoted')) THEN
        RAISE EXCEPTION 'managed relation has an active migration or replication dependency' USING ERRCODE='55000'; END IF;
END $$;

CREATE OR REPLACE FUNCTION splitjson.create_partitioned_table(p_name text,p_paths jsonb,p_columns jsonb,p_partition_spec jsonb) RETURNS regclass
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    parts text[];
    logical_name text;
    storage_name text;
    columns text := '';
    n integer;
    column_name text;
    declared_type jsonb;
    normalized_type text;
    normalized_columns jsonb := '{}';
    extra_select text := '';
    strategy text; modulus integer; bounds jsonb; lower_bound bigint; upper_bound bigint; leaf text;
BEGIN
    IF p_name IS NULL OR p_paths IS NULL OR p_columns IS NULL THEN
        RAISE EXCEPTION 'table name and paths must not be NULL' USING ERRCODE = '22023';
    END IF;
    IF p_partition_spec IS NULL THEN RAISE EXCEPTION 'partition spec must not be NULL' USING ERRCODE='22023'; END IF;
    IF jsonb_typeof(p_partition_spec)='object' THEN
        IF (SELECT count(*) FROM jsonb_object_keys(p_partition_spec))<>2 OR
           p_partition_spec->>'strategy'<>'hash' OR jsonb_typeof(p_partition_spec->'modulus')<>'number' OR
           (p_partition_spec->>'modulus') !~ '^[1-9][0-9]*$' THEN
            RAISE EXCEPTION 'hash specification requires only strategy=hash and integer modulus' USING ERRCODE='22023'; END IF;
        modulus:=(p_partition_spec->>'modulus')::integer;
        IF modulus NOT BETWEEN 1 AND 64 THEN RAISE EXCEPTION 'hash modulus must be 1..64' USING ERRCODE='22023'; END IF;
        strategy:='hash';
    ELSIF jsonb_typeof(p_partition_spec)='array' AND jsonb_array_length(p_partition_spec) BETWEEN 1 AND 64 THEN
        strategy:='range';
        FOR bounds IN SELECT value FROM jsonb_array_elements(p_partition_spec) LOOP
            PERFORM splitjson._range_bound(bounds);
        END LOOP;
    ELSE RAISE EXCEPTION 'partition specification must be hash or 1..64 range bounds' USING ERRCODE='22023'; END IF;
    PERFORM splitjson.validate_paths(p_paths);
    IF jsonb_array_length(p_paths) = 0 THEN
        RAISE EXCEPTION 'declare at least one hot path' USING ERRCODE = '22023';
    END IF;
    parts := parse_ident(p_name, true);
    IF cardinality(parts) <> 2 THEN
        RAISE EXCEPTION 'use a schema-qualified name, for example public.docs' USING ERRCODE = '22023';
    END IF;
    -- Avoid PostgreSQL identifier truncation creating ambiguous metadata names.
    IF octet_length(parts[1]) > 63 OR octet_length(parts[2]) > 63 THEN
        RAISE EXCEPTION 'schema and relation names must fit PostgreSQL identifiers' USING ERRCODE = '22023';
    END IF;
    logical_name := format('%I.%I', parts[1], parts[2]);
    IF jsonb_typeof(p_columns)<>'object' OR (SELECT count(*) FROM jsonb_object_keys(p_columns))>64 THEN
        RAISE EXCEPTION 'business columns must be an object with at most 64 entries' USING ERRCODE='22023';
    END IF;
    n := 0;
    FOR column_name,declared_type IN SELECT key,value FROM jsonb_each(p_columns) ORDER BY key COLLATE "C" LOOP
        IF column_name IN ('id','doc') OR column_name='' OR octet_length(column_name)>63 OR jsonb_typeof(declared_type)<>'string' THEN
            RAISE EXCEPTION 'invalid business column name or type declaration' USING ERRCODE='22023';
        END IF;
        normalized_type := splitjson.column_type(declared_type #>> '{}');
        normalized_columns := normalized_columns || jsonb_build_object(column_name,normalized_type);
        n := n+1;
        columns := columns || format(',extra_%s %s',n,normalized_type);
        extra_select := extra_select || format(',extra_%s AS %I',n,column_name);
    END LOOP;
    storage_name := format('splitjson_storage.s_%s', nextval('splitjson._table_id_seq'));
    FOR n IN 1..jsonb_array_length(p_paths) LOOP
        columns := columns || format(',hot_%s jsonb', n);
    END LOOP;
    EXECUTE format('CREATE TABLE %s (id bigint PRIMARY KEY,cold splitjson.cold NOT NULL%s) PARTITION BY %s(id)',storage_name,columns,upper(strategy));
    EXECUTE format('ALTER TABLE %s ALTER COLUMN cold SET STORAGE EXTERNAL', storage_name);
    EXECUTE format('CREATE VIEW %s WITH (security_barrier=true) AS '
                   'SELECT id,splitjson.restore(cold,%s,%L::jsonb) AS doc%s FROM %s',
                   logical_name,splitjson._hot_array(p_paths),p_paths::text,extra_select,storage_name);
    IF strategy='hash' THEN
        FOR n IN 0..modulus-1 LOOP
            leaf:=storage_name||'_p'||n;
            EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES WITH (MODULUS %s,REMAINDER %s) WITH (fillfactor=70)',leaf,storage_name,modulus,n);
            PERFORM splitjson._secure_relation(leaf::regclass);
        END LOOP;
    ELSE
        n:=0;
        FOR bounds IN SELECT value FROM jsonb_array_elements(p_partition_spec) LOOP
            leaf:=storage_name||'_p'||n; n:=n+1;
            EXECUTE format('CREATE TABLE %s PARTITION OF %s %s WITH (fillfactor=70)',leaf,storage_name,splitjson._range_bound(bounds));
            PERFORM splitjson._secure_relation(leaf::regclass);
        END LOOP;
    END IF;
    PERFORM splitjson._secure_relation(storage_name::regclass);
    INSERT INTO splitjson._tables(view_name,storage_name,paths,business_columns,view_definition,storage_definition,storage_mode,partition_spec)
        VALUES(logical_name,storage_name,p_paths,normalized_columns,splitjson._view_definition(logical_name::regclass),
               splitjson._storage_definition(storage_name::regclass),strategy,p_partition_spec);
    PERFORM splitjson._register_leaves(logical_name::regclass,storage_name::regclass);
    EXECUTE format('CREATE TRIGGER pg_splitjson_write INSTEAD OF INSERT OR UPDATE OR DELETE ON %s '
                   'FOR EACH ROW EXECUTE FUNCTION splitjson._view_write()', logical_name);
    RETURN logical_name::regclass;
END $$;


CREATE FUNCTION splitjson.create_partition(p_table regclass,p_name text,p_from bigint,p_to bigint)
RETURNS regclass LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; leaf text; parts text[];
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    parts:=parse_ident(p_name,true);
    IF m.storage_mode<>'range' OR p_name IS NULL OR cardinality(parts)<>1 OR octet_length(parts[1])>63 THEN
        RAISE EXCEPTION 'use a simple leaf name for RANGE(id) storage' USING ERRCODE='22023'; END IF;
    leaf:=format('splitjson_storage.%I',parts[1]);
    IF to_regclass(leaf) IS NOT NULL THEN RAISE EXCEPTION 'partition already exists' USING ERRCODE='42P07'; END IF;
    EXECUTE format('CREATE TABLE %s PARTITION OF %s %s WITH (fillfactor=70)',leaf,m.storage_name,
        splitjson._range_bound(jsonb_build_object('from',p_from,'to',p_to)));
    PERFORM splitjson._secure_relation(leaf::regclass);
    EXECUTE format('ALTER TABLE %s ALTER COLUMN cold SET STORAGE EXTERNAL',leaf);
    PERFORM splitjson._register_leaves(p_table,m.storage_name::regclass);
    RETURN leaf::regclass;
END $$;

CREATE FUNCTION splitjson.attach_partition(p_table regclass,p_partition regclass,p_from bigint,p_to bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; installer oid;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    SELECT extowner INTO installer FROM pg_extension WHERE extname='pg_splitjson';
    IF m.storage_mode<>'range' OR p_partition IS NULL OR
       NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=p_partition AND relkind='r' AND relowner=installer AND relpersistence='p'
          AND relnamespace='splitjson_storage'::regnamespace AND NOT relrowsecurity AND NOT relforcerowsecurity) OR
       splitjson._storage_definition(p_partition) IS DISTINCT FROM m.storage_definition OR
       EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid=p_partition OR inhparent=p_partition) OR
       EXISTS(SELECT 1 FROM pg_policy WHERE polrelid=p_partition) OR
       EXISTS(SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid=p_partition AND a.grantee<>installer) OR
       EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=p_partition AND NOT tgisinternal AND tgfoid<>'splitjson._revision_write()'::regprocedure) THEN
        RAISE EXCEPTION 'partition layout, ownership or security mismatch' USING ERRCODE='55000'; END IF;
    EXECUTE format('ALTER TABLE %s ATTACH PARTITION %s %s',m.storage_name,p_partition,
        splitjson._range_bound(jsonb_build_object('from',p_from,'to',p_to)));
    PERFORM splitjson._register_leaves(p_table,m.storage_name::regclass);
END $$;

CREATE FUNCTION splitjson.detach_partition(p_table regclass,p_partition regclass)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    IF m.storage_mode<>'range' OR p_partition IS NULL OR NOT EXISTS(SELECT 1 FROM splitjson._leaves WHERE view_name=m.view_name AND relation_name=splitjson._qualified_name(p_partition)) THEN
        RAISE EXCEPTION 'partition is not a registered RANGE leaf' USING ERRCODE='22023'; END IF;
    EXECUTE format('ALTER TABLE %s DETACH PARTITION %s',m.storage_name,p_partition);
    DELETE FROM splitjson._leaves WHERE relation_name=splitjson._qualified_name(p_partition);
    UPDATE splitjson._tables SET partition_spec=coalesce((SELECT jsonb_agg(l.bound_spec ORDER BY (l.bound_spec->>'from')::bigint NULLS FIRST)
        FROM splitjson._leaves l WHERE l.view_name=m.view_name),'[]') WHERE view_name=m.view_name;
END $$;
