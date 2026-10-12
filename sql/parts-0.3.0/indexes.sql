CREATE FUNCTION splitjson._collation(p_name name) RETURNS regcollation
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp
AS $$
DECLARE names text[]; qualified text; result regcollation;
BEGIN
    IF p_name IS NULL THEN RETURN NULL; END IF;
    names:=CASE WHEN position('.' in p_name::text)=0 AND position('"' in p_name::text)=0 THEN ARRAY[p_name::text] ELSE parse_ident(p_name::text,true) END;
    IF cardinality(names)=1 THEN qualified:=quote_ident(names[1]);
    ELSIF cardinality(names)=2 THEN qualified:=format('%I.%I',names[1],names[2]);
    ELSE RAISE EXCEPTION 'invalid collation name' USING ERRCODE='22023'; END IF;
    result:=to_regcollation(qualified);
    IF result IS NULL THEN RAISE EXCEPTION 'collation does not exist' USING ERRCODE='42704'; END IF;
    RETURN result;
END $$;

CREATE FUNCTION splitjson._index_expression(p_slot integer,p_kind text,p_collation name) RETURNS text
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp
AS $$
DECLARE result text; coll regcollation; qualified text;
BEGIN
    IF p_slot IS NULL OR p_kind IS NULL OR p_kind NOT IN ('jsonb','text','numeric','boolean') OR (p_kind<>'text' AND p_collation IS NOT NULL) THEN
        RAISE EXCEPTION 'invalid index kind or collation' USING ERRCODE='22023'; END IF;
    result:=format('hot_%s',p_slot);
    IF p_kind='text' THEN
        result:=format('(%s #>> %L::text[])',result,'{}'); coll:=splitjson._collation(p_collation);
        IF coll IS NOT NULL THEN SELECT format('%I.%I',n.nspname,c.collname) INTO qualified FROM pg_collation c JOIN pg_namespace n ON n.oid=c.collnamespace WHERE c.oid=coll;
            result:=format('(%s COLLATE %s)',result,qualified); END IF;
    ELSIF p_kind IN ('numeric','boolean') THEN
        result:=format('(CASE WHEN jsonb_typeof(hot_%s)=%L THEN (hot_%s #>> %L::text[])::%s END)',
            p_slot,CASE WHEN p_kind='numeric' THEN 'number' ELSE 'boolean' END,p_slot,'{}',p_kind);
    END IF;
    RETURN result;
END $$;

CREATE FUNCTION splitjson.declare_path_type(p_table regclass,p_path jsonb,p_kind text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; slot integer; guard text; typ text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    IF p_kind IS NULL OR p_kind NOT IN ('numeric','boolean') THEN RAISE EXCEPTION 'type must be numeric or boolean' USING ERRCODE='22023'; END IF;
    SELECT ord::integer INTO slot FROM jsonb_array_elements(m.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'type declaration requires an exact registered hot path' USING ERRCODE='22023'; END IF;
    IF EXISTS(SELECT 1 FROM splitjson._slot_types WHERE view_name=m.view_name AND path=p_path AND kind<>p_kind) THEN
        RAISE EXCEPTION 'hot slot already has a different type' USING ERRCODE='22023'; END IF;
    guard:=format('pg_splitjson_type_%s_%s',slot,p_kind); typ:=CASE WHEN p_kind='numeric' THEN 'number' ELSE 'boolean' END;
    IF NOT EXISTS(SELECT 1 FROM splitjson._slot_types WHERE view_name=m.view_name AND path=p_path) THEN
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (hot_%s IS NULL OR hot_%s=''null''::jsonb OR jsonb_typeof(hot_%s)=%L)',m.storage_name,guard,slot,slot,slot,typ);
        INSERT INTO splitjson._slot_types(view_name,path,kind,guard_name,definition)
            SELECT m.view_name,p_path,p_kind,guard,pg_get_constraintdef(oid,true) FROM pg_constraint WHERE conrelid=m.storage_name::regclass AND conname=guard;
    END IF;
END $$;

CREATE FUNCTION splitjson.register_path_index(p_table regclass,p_index regclass,p_path jsonb,p_kind text,p_collation name DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; slot integer; expression text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table);
    SELECT ord::integer INTO slot FROM jsonb_array_elements(m.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'index must address an exact hot slot' USING ERRCODE='22023'; END IF;
    expression:=splitjson._index_expression(slot,p_kind,p_collation);
    IF p_kind IN ('numeric','boolean') AND NOT EXISTS(SELECT 1 FROM splitjson._slot_types WHERE view_name=m.view_name AND path=p_path AND kind=p_kind) THEN
        RAISE EXCEPTION 'declare matching path type before registering a typed index' USING ERRCODE='55000'; END IF;
    IF NOT splitjson._index_match(p_index,m.storage_name::regclass,expression) THEN
        RAISE EXCEPTION 'index expression, validity or layout does not match' USING ERRCODE='55000'; END IF;
    INSERT INTO splitjson._path_indexes(view_name,index_name,path,kind,collation_name,expression,definition)
        VALUES(m.view_name,splitjson._qualified_name(p_index),p_path,p_kind,splitjson._collation(p_collation)::text,expression,pg_get_indexdef(p_index))
        ON CONFLICT(index_name) DO UPDATE SET path=EXCLUDED.path,kind=EXCLUDED.kind,collation_name=EXCLUDED.collation_name,expression=EXCLUDED.expression,definition=EXCLUDED.definition;
END $$;

CREATE FUNCTION splitjson.create_path_index(p_table regclass,p_name text,p_path jsonb,p_kind text,p_collation name)
RETURNS regclass LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; slot integer; names text[]; expression text; idx regclass;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); PERFORM splitjson._assert_idle(p_table); names:=parse_ident(p_name,true);
    IF p_name IS NULL OR cardinality(names)<>1 OR octet_length(names[1])>63 THEN RAISE EXCEPTION 'use a simple index name' USING ERRCODE='22023'; END IF;
    SELECT ord::integer INTO slot FROM jsonb_array_elements(m.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'index requires an exact hot slot' USING ERRCODE='22023'; END IF;
    expression:=splitjson._index_expression(slot,p_kind,p_collation);
    IF p_kind IN ('numeric','boolean') THEN PERFORM splitjson._api_declare_path_type(p_table,p_path,p_kind); END IF;
    EXECUTE format('CREATE INDEX %I ON %s USING btree (%s)',names[1],m.storage_name,expression);
    idx:=format('splitjson_storage.%I',names[1])::regclass;
    PERFORM splitjson._api_register_path_index(p_table,idx,p_path,p_kind,p_collation);
    RETURN idx;
END $$;
CREATE OR REPLACE FUNCTION splitjson._create_index(p_table regclass,p_name text,p_slot integer,p_kind text) RETURNS regclass
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT');
    RETURN splitjson._api_create_path_index(p_table,p_name,m.paths->(p_slot-1),p_kind,NULL);
END $$;

CREATE FUNCTION splitjson.create_path_index(p_table regclass,p_name text,p_path text[],p_kind text,p_collation name)
RETURNS regclass LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
RETURN splitjson._api_create_path_index(p_table,p_name,to_jsonb(p_path),p_kind,p_collation);

CREATE FUNCTION splitjson.index_ddl(p_table regclass,p_name text,p_path jsonb,p_kind text,p_unique boolean,p_collation name)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; slot integer; names text[]; expression text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); names:=parse_ident(p_name,true);
    IF p_name IS NULL OR p_unique IS NULL OR cardinality(names)<>1 OR octet_length(names[1])>63 OR m.storage_mode<>'heap' THEN
        RAISE EXCEPTION 'use a simple index name and heap storage; partition_index_ddl handles partitioned storage' USING ERRCODE='22023'; END IF;
    SELECT ord::integer INTO slot FROM jsonb_array_elements(m.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'index requires exact hot slot' USING ERRCODE='22023'; END IF;
    expression:=splitjson._index_expression(slot,p_kind,p_collation);
    IF p_kind IN ('numeric','boolean') AND NOT EXISTS(SELECT 1 FROM splitjson._slot_types WHERE view_name=m.view_name AND path=p_path AND kind=p_kind) THEN
        RAISE EXCEPTION 'run declare_path_type before generating typed concurrent DDL' USING ERRCODE='55000'; END IF;
    RETURN format('CREATE %sINDEX CONCURRENTLY %I ON %s USING btree (%s);',CASE WHEN p_unique THEN 'UNIQUE ' ELSE '' END,names[1],m.storage_name,expression);
END $$;
CREATE OR REPLACE FUNCTION splitjson.index_ddl(p_table regclass,p_name text,p_path jsonb,p_kind text DEFAULT 'jsonb',p_unique boolean DEFAULT false)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
RETURN splitjson._api_index_ddl(p_table,p_name,p_path,p_kind,p_unique,NULL);

CREATE FUNCTION splitjson.partition_index_ddl(p_table regclass,p_name text,p_path jsonb,p_kind text DEFAULT 'jsonb',p_collation name DEFAULT NULL)
RETURNS SETOF text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; slot integer; names text[]; expr text; leaf text; idx text; parent text;
BEGIN
    m:=splitjson._lookup(p_table,'SELECT'); names:=parse_ident(p_name,true);
    IF p_name IS NULL OR cardinality(names)<>1 OR octet_length(names[1])>63 OR m.storage_mode='heap' THEN
        RAISE EXCEPTION 'use a simple index name and partitioned storage' USING ERRCODE='22023'; END IF;
    SELECT ord::integer INTO slot FROM jsonb_array_elements(m.paths) WITH ORDINALITY p(path,ord) WHERE path=p_path;
    IF slot IS NULL THEN RAISE EXCEPTION 'index requires an exact hot path' USING ERRCODE='22023'; END IF;
    expr:=splitjson._index_expression(slot,p_kind,p_collation); parent:=format('splitjson_storage.%I',names[1]);
    IF p_kind IN ('numeric','boolean') THEN RETURN NEXT format('SELECT splitjson.declare_path_type(%L::regclass,%L::jsonb,%L);',m.view_name,p_path,p_kind); END IF;
    RETURN NEXT format('CREATE INDEX %I ON ONLY %s USING btree (%s);',names[1],m.storage_name,expr);
    FOR leaf IN SELECT relation_name FROM splitjson._leaves WHERE view_name=m.view_name ORDER BY relation_name LOOP
        idx:=format('splitjson_storage.%I',left(names[1],38)||'_'||substr(md5(leaf),1,16));
        RETURN NEXT format('CREATE INDEX CONCURRENTLY %I ON %s USING btree (%s);',(parse_ident(idx,true))[2],leaf,expr);
        RETURN NEXT format('ALTER INDEX %s ATTACH PARTITION %s;',parent,idx);
    END LOOP;
    RETURN NEXT format('SELECT splitjson.register_path_index(%L::regclass,%L::regclass,%L::jsonb,%L,%L::name);',m.view_name,parent,p_path,p_kind,p_collation);
END $$;

CREATE OR REPLACE FUNCTION splitjson.find_ids_range(p_table regclass,p_path text[],p_kind text,p_lower jsonb DEFAULT NULL,p_upper jsonb DEFAULT NULL,
    p_include_lower boolean DEFAULT true,p_include_upper boolean DEFAULT false,p_collation name DEFAULT NULL)
RETURNS SETOF bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; slots integer[]; slot integer; expr text; conditions text; json_type text; dtype regtype;
BEGIN
    IF p_path IS NULL OR p_kind IS NULL OR p_include_lower IS NULL OR p_include_upper IS NULL OR p_kind NOT IN ('numeric','boolean','text') THEN
        RAISE EXCEPTION 'invalid typed range arguments' USING ERRCODE='22023'; END IF;
    PERFORM splitjson.assert_object_path('{}',p_path);
    m:=splitjson._lookup(p_table,'SELECT'); slots:=splitjson._path_candidates(m.paths,p_path);
    IF cardinality(slots)<>1 THEN RAISE EXCEPTION 'range requires a unique declared hot slot' USING ERRCODE='22023'; END IF;
    slot:=slots[1]; json_type:=CASE WHEN p_kind='numeric' THEN 'number' WHEN p_kind='text' THEN 'string' ELSE 'boolean' END;
    IF (p_lower IS NOT NULL AND jsonb_typeof(p_lower)<>json_type) OR (p_upper IS NOT NULL AND jsonb_typeof(p_upper)<>json_type) THEN
        RAISE EXCEPTION 'range bound has wrong JSON type' USING ERRCODE='22023'; END IF;
    IF p_lower IS NOT NULL AND p_upper IS NOT NULL AND p_kind<>'text' AND p_lower>p_upper THEN
        RAISE EXCEPTION 'lower bound exceeds upper bound' USING ERRCODE='22023'; END IF;
    IF p_kind IN ('numeric','boolean') AND NOT EXISTS(SELECT 1 FROM splitjson._slot_types WHERE view_name=m.view_name AND path=m.paths->(slot-1) AND kind=p_kind) THEN
        RAISE EXCEPTION 'declare a matching path type before using typed ranges' USING ERRCODE='55000'; END IF;
    expr:=splitjson._index_expression(slot,p_kind,p_collation); dtype:=p_kind::regtype;
    conditions:=expr||' IS NOT NULL';
    IF p_lower IS NOT NULL THEN conditions:=conditions||format(' AND %s %s $1',expr,CASE WHEN p_include_lower THEN '>=' ELSE '>' END); END IF;
    IF p_upper IS NOT NULL THEN conditions:=conditions||format(' AND %s %s $2',expr,CASE WHEN p_include_upper THEN '<=' ELSE '<' END); END IF;
    RETURN QUERY SELECT q.id FROM splitjson._query(format('SELECT id FROM %s WHERE %s',m.storage_name,conditions),
        ARRAY[dtype,dtype]::regtype[],ARRAY[p_lower #>> '{}',p_upper #>> '{}'],true) q(id bigint);
END $$;
