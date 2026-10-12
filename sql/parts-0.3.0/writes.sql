CREATE OR REPLACE FUNCTION splitjson.row_revision(p_table regclass,p_id bigint)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; revision bigint; affected bigint;
BEGIN
    IF p_id IS NULL THEN RAISE EXCEPTION 'id must not be NULL' USING ERRCODE='22023'; END IF;
    m := splitjson._lookup(p_table,'SELECT');
    SELECT q.value INTO revision FROM splitjson._query(format('SELECT row_revision FROM %s WHERE id=$1',m.storage_name),
        ARRAY['bigint']::regtype[],ARRAY[p_id::text],true) AS q(value bigint);
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected=0 THEN RETURN NULL; END IF;
    RETURN splitjson._token(m.layout_epoch,p_id,revision);
END $$;
REVOKE ALL ON FUNCTION splitjson.row_revision(regclass,bigint) FROM PUBLIC;

CREATE OR REPLACE FUNCTION splitjson.set_fields_if_revision(p_table regclass,p_id bigint,p_token text,
                                                            p_updates jsonb,p_create_missing boolean DEFAULT true)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; revision bigint; affected bigint;
BEGIN
    IF p_id IS NULL OR p_token IS NULL OR p_updates IS NULL THEN
        RAISE EXCEPTION 'id, token and updates must not be NULL' USING ERRCODE='22023';
    END IF;
    m := splitjson._lookup(p_table,'UPDATE');
    SELECT q.value INTO revision FROM splitjson._query(format('SELECT row_revision FROM %s WHERE id=$1 FOR UPDATE',m.storage_name),
        ARRAY['bigint']::regtype[],ARRAY[p_id::text],false) AS q(value bigint);
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected=0 THEN RETURN NULL; END IF;
    IF splitjson._token_revision(p_token,m.layout_epoch,p_id)<>revision THEN RAISE EXCEPTION 'stale revision token' USING ERRCODE='40001'; END IF;
    IF splitjson._api_set_fields(p_table,p_id,p_updates,p_create_missing) IS DISTINCT FROM true THEN RETURN NULL; END IF;
    SELECT q.value INTO revision FROM splitjson._query(format('SELECT row_revision FROM %s WHERE id=$1',m.storage_name),
        ARRAY['bigint']::regtype[],ARRAY[p_id::text],false) AS q(value bigint);
    RETURN splitjson._token(m.layout_epoch,p_id,revision);
END $$;
REVOKE ALL ON FUNCTION splitjson.set_fields_if_revision(regclass,bigint,text,jsonb,boolean) FROM PUBLIC;

CREATE OR REPLACE FUNCTION splitjson._pointer(p_pointer text) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
AS $$
DECLARE raw text[]; result text[] := '{}'; token text; i integer;
BEGIN
    IF p_pointer='' THEN RETURN result; END IF;
    IF left(p_pointer,1)<>'/' THEN RAISE EXCEPTION 'JSON Pointer must start with /' USING ERRCODE='22023'; END IF;
    raw:=CASE WHEN p_pointer='/' THEN ARRAY[''] ELSE string_to_array(substr(p_pointer,2),'/') END;
    FOR i IN 1..cardinality(raw) LOOP
        token:=raw[i];
        IF token ~ '~([^01]|$)' THEN RAISE EXCEPTION 'invalid JSON Pointer escape' USING ERRCODE='22023'; END IF;
        result:=array_append(result,replace(replace(token,'~1','/'),'~0','~'));
    END LOOP;
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION splitjson._patch_get(p_doc jsonb,p_path text[]) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
AS $$
DECLARE value jsonb:=p_doc; part text;
BEGIN
    FOREACH part IN ARRAY p_path LOOP
        IF jsonb_typeof(value)='array' THEN
            IF part !~ '^(0|[1-9][0-9]*)$' THEN RAISE EXCEPTION 'invalid JSON Pointer array index' USING ERRCODE='22023'; END IF;
            IF part::numeric>=jsonb_array_length(value) THEN RETURN NULL; END IF;
            value:=value->part::integer;
        ELSIF jsonb_typeof(value)='object' THEN value:=value->part;
        ELSE RETURN NULL; END IF;
        IF value IS NULL THEN RETURN NULL; END IF;
    END LOOP;
    RETURN value;
END $$;

CREATE OR REPLACE FUNCTION splitjson._patch_exists(p_doc jsonb,p_path text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
RETURN splitjson._patch_get(p_doc,p_path) IS NOT NULL;

CREATE OR REPLACE FUNCTION splitjson._patch_add(p_doc jsonb,p_path text[],p_value jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
AS $$
DECLARE parent text[]; key text; target jsonb; index integer; replacement jsonb;
BEGIN
    IF cardinality(p_path)=0 THEN RETURN p_value; END IF;
    parent:=p_path[1:cardinality(p_path)-1]; key:=p_path[cardinality(p_path)];
    target:=splitjson._patch_get(p_doc,parent);
    IF target IS NULL THEN RAISE EXCEPTION 'JSON Patch parent does not exist' USING ERRCODE='22023'; END IF;
    IF jsonb_typeof(target)='array' THEN
        IF key='-' THEN index:=jsonb_array_length(target);
        ELSIF key ~ '^(0|[1-9][0-9]*)$' THEN
            IF key::numeric>jsonb_array_length(target) THEN RAISE EXCEPTION 'JSON Patch array index is out of range' USING ERRCODE='22023'; END IF;
            index:=key::integer;
        ELSE RAISE EXCEPTION 'JSON Patch array index is invalid' USING ERRCODE='22023'; END IF;
        IF index<0 OR index>jsonb_array_length(target) THEN RAISE EXCEPTION 'JSON Patch array index is out of range' USING ERRCODE='22023'; END IF;
        replacement:=jsonb_insert(target,ARRAY[index::text],p_value,false);
    ELSIF jsonb_typeof(target)='object' THEN replacement:=jsonb_set(target,ARRAY[key],p_value,true);
    ELSE RAISE EXCEPTION 'JSON Patch parent is not a container' USING ERRCODE='22023'; END IF;
    IF cardinality(parent)=0 THEN RETURN replacement; END IF;
    RETURN jsonb_set(p_doc,parent,replacement,false);
END $$;

CREATE OR REPLACE FUNCTION splitjson._patch_remove(p_doc jsonb,p_path text[]) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
AS $$
DECLARE parent text[]; key text; target jsonb; index integer; replacement jsonb;
BEGIN
    IF cardinality(p_path)=0 THEN RAISE EXCEPTION 'root remove is unsupported because doc is mandatory' USING ERRCODE='0A000'; END IF;
    IF NOT splitjson._patch_exists(p_doc,p_path) THEN RAISE EXCEPTION 'JSON Patch remove target does not exist' USING ERRCODE='22023'; END IF;
    parent:=p_path[1:cardinality(p_path)-1]; key:=p_path[cardinality(p_path)];
    target:=splitjson._patch_get(p_doc,parent);
    IF jsonb_typeof(target)='array' THEN
        IF key !~ '^(0|[1-9][0-9]*)$' THEN RAISE EXCEPTION 'JSON Patch array index is invalid' USING ERRCODE='22023'; END IF;
        index:=key::integer;
        IF index<0 OR index>=jsonb_array_length(target) THEN RAISE EXCEPTION 'JSON Patch array index is out of range' USING ERRCODE='22023'; END IF;
        replacement:=target-index;
    ELSIF jsonb_typeof(target)='object' THEN replacement:=target-key;
    ELSE RAISE EXCEPTION 'JSON Patch parent is not a container' USING ERRCODE='22023'; END IF;
    IF cardinality(parent)=0 THEN RETURN replacement; END IF;
    RETURN jsonb_set(p_doc,parent,replacement,false);
END $$;

CREATE OR REPLACE FUNCTION splitjson._apply_patch_doc(p_doc jsonb,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog, pg_temp
AS $$
DECLARE operation jsonb; op text; path text[]; from_path text[]; source jsonb; result jsonb:=p_doc;
BEGIN
    IF jsonb_typeof(p_patch)<>'array' OR jsonb_array_length(p_patch)>64 THEN RAISE EXCEPTION 'JSON Patch must contain 0 to 64 operations' USING ERRCODE='22023'; END IF;
    FOR operation IN SELECT value FROM jsonb_array_elements(p_patch) LOOP
        IF jsonb_typeof(operation)<>'object' OR NOT operation ? 'op' OR NOT operation ? 'path' OR jsonb_typeof(operation->'path')<>'string' THEN
            RAISE EXCEPTION 'JSON Patch operation requires string op and path' USING ERRCODE='22023';
        END IF;
        op:=operation->>'op'; path:=splitjson._pointer(operation->>'path');
        IF op IN ('add','replace','test') AND NOT operation ? 'value' THEN RAISE EXCEPTION 'JSON Patch operation requires value' USING ERRCODE='22023'; END IF;
        IF op='add' THEN result:=splitjson._patch_add(result,path,operation->'value');
        ELSIF op='remove' THEN result:=splitjson._patch_remove(result,path);
        ELSIF op='replace' THEN
            IF NOT splitjson._patch_exists(result,path) THEN RAISE EXCEPTION 'JSON Patch replace target does not exist' USING ERRCODE='22023'; END IF;
            result:=CASE WHEN cardinality(path)=0 THEN operation->'value' ELSE jsonb_set(result,path,operation->'value',false) END;
        ELSIF op='test' THEN
            IF NOT splitjson._patch_exists(result,path) OR (CASE WHEN cardinality(path)=0 THEN result ELSE result #> path END) IS DISTINCT FROM operation->'value' THEN RAISE EXCEPTION 'JSON Patch test failed' USING ERRCODE='40001'; END IF;
        ELSIF op IN ('copy','move') THEN
            IF NOT operation ? 'from' OR jsonb_typeof(operation->'from')<>'string' THEN RAISE EXCEPTION 'JSON Patch copy/move requires from' USING ERRCODE='22023'; END IF;
            from_path:=splitjson._pointer(operation->>'from');
            IF NOT splitjson._patch_exists(result,from_path) THEN RAISE EXCEPTION 'JSON Patch source does not exist' USING ERRCODE='22023'; END IF;
            IF op='move' AND cardinality(path)>cardinality(from_path) AND (cardinality(from_path)=0 OR path[1:cardinality(from_path)]=from_path) THEN RAISE EXCEPTION 'JSON Patch cannot move into its own descendant' USING ERRCODE='22023'; END IF;
            source:=CASE WHEN cardinality(from_path)=0 THEN result ELSE result #> from_path END;
            IF op='move' AND from_path=path THEN CONTINUE; END IF;
            IF op='move' THEN result:=splitjson._patch_remove(result,from_path); END IF;
            result:=splitjson._patch_add(result,path,source);
        ELSE RAISE EXCEPTION 'unsupported JSON Patch operation: %',op USING ERRCODE='22023'; END IF;
    END LOOP;
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION splitjson.apply_patch(p_table regclass,p_id bigint,p_patch jsonb,p_expected_revision text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; old_doc jsonb; new_doc jsonb; revision bigint; affected bigint;
    hot jsonb[]; operation jsonb; converted jsonb; op text; path text[]; from_path text[]; relative text[];
    slot integer; source_slot integer; depth integer; touched integer[]:='{}'; all_hot boolean:=true;
    assignments text; source_value jsonb; did_write boolean:=false;
BEGIN
    IF p_id IS NULL OR p_patch IS NULL OR jsonb_typeof(p_patch)<>'array' OR jsonb_array_length(p_patch)>64 THEN
        RAISE EXCEPTION 'JSON Patch must contain 0 to 64 operations' USING ERRCODE='22023'; END IF;
    -- Validate syntax even if the row is absent, without evaluating test.
    FOR operation IN SELECT value FROM jsonb_array_elements(p_patch) LOOP
        op:=operation->>'op';
        IF jsonb_typeof(operation)<>'object' OR jsonb_typeof(operation->'op')<>'string' OR
           jsonb_typeof(operation->'path')<>'string' OR op NOT IN ('add','remove','replace','move','copy','test') OR
           (op IN ('add','replace','test') AND NOT operation ? 'value') OR
           (op IN ('move','copy') AND jsonb_typeof(operation->'from') IS DISTINCT FROM 'string') THEN
            RAISE EXCEPTION 'invalid JSON Patch operation' USING ERRCODE='22023'; END IF;
        PERFORM splitjson._pointer(operation->>'path');
        IF op IN ('move','copy') THEN PERFORM splitjson._pointer(operation->>'from'); END IF;
        IF op='remove' AND operation->>'path'='' THEN RAISE EXCEPTION 'root remove requires an absent document' USING ERRCODE='0A000'; END IF;
    END LOOP;
    m:=splitjson._lookup(p_table,'UPDATE');
    SELECT q.hot_values,q.rev INTO hot,revision FROM splitjson._query(
        format('SELECT %s,row_revision FROM %s WHERE id=$1 FOR UPDATE',splitjson._hot_array(m.paths),m.storage_name),
        ARRAY['bigint']::regtype[],ARRAY[p_id::text],false) AS q(hot_values jsonb[],rev bigint);
    GET DIAGNOSTICS affected=ROW_COUNT; IF affected=0 THEN RETURN NULL; END IF;
    IF p_expected_revision IS NOT NULL AND splitjson._token_revision(p_expected_revision,m.layout_epoch,p_id)<>revision THEN
        RAISE EXCEPTION 'stale revision token' USING ERRCODE='40001'; END IF;
    FOR operation IN SELECT value FROM jsonb_array_elements(p_patch) LOOP
        op:=operation->>'op'; path:=splitjson._pointer(operation->>'path');
        IF cardinality(path)=0 THEN all_hot:=false; EXIT; END IF;
        slot:=splitjson._hot_route(m.paths,path,hot);
        IF slot IS NULL THEN all_hot:=false; EXIT; END IF;
        depth:=jsonb_array_length(m.paths->(slot-1)); relative:=path[depth+1:cardinality(path)];
        IF op='remove' AND cardinality(relative)=0 THEN all_hot:=false; EXIT; END IF;
        converted:=jsonb_set(operation,'{path}',to_jsonb(CASE WHEN cardinality(relative)=0 THEN '' ELSE
            '/'||array_to_string(ARRAY(SELECT replace(replace(k,'~','~0'),'/','~1') FROM unnest(relative) k),'/') END));
        IF op IN ('copy','move') THEN
            from_path:=splitjson._pointer(operation->>'from');
            IF op='move' AND cardinality(path)>cardinality(from_path) AND
               (cardinality(from_path)=0 OR path[1:cardinality(from_path)]=from_path) THEN
                RAISE EXCEPTION 'cannot move a value into its descendant' USING ERRCODE='22023'; END IF;
            source_slot:=splitjson._hot_route(m.paths,from_path,hot);
            IF source_slot IS NULL THEN all_hot:=false; EXIT; END IF;
            from_path:=from_path[jsonb_array_length(m.paths->(source_slot-1))+1:cardinality(from_path)];
            source_value:=splitjson._patch_get(hot[source_slot],from_path);
            IF source_value IS NULL THEN RAISE EXCEPTION 'JSON Patch source is absent' USING ERRCODE='22023'; END IF;
            IF op='move' THEN
                IF source_slot=slot AND from_path=relative THEN CONTINUE; END IF;
                IF cardinality(from_path)=0 THEN all_hot:=false; EXIT; END IF;
                hot[source_slot]:=splitjson._patch_remove(hot[source_slot],from_path);
                touched:=array_append(touched,source_slot);
            END IF;
            hot[slot]:=splitjson._patch_add(hot[slot],relative,source_value);
        ELSE
            hot[slot]:=splitjson._apply_patch_doc(hot[slot],jsonb_build_array(converted));
        END IF;
        IF op<>'test' THEN touched:=array_append(touched,slot); END IF;
    END LOOP;
    IF all_hot THEN
        IF cardinality(touched)=0 THEN RETURN splitjson._token(m.layout_epoch,p_id,revision); END IF;
        SELECT string_agg(format('hot_%s=($1)[%s]',n,n),',' ORDER BY n) INTO assignments
            FROM (SELECT DISTINCT unnest(touched) AS n) s;
        SELECT q.rev INTO revision FROM splitjson._query(format('UPDATE %s SET %s WHERE id=$2 RETURNING row_revision',m.storage_name,assignments),
            ARRAY['jsonb[]','bigint']::regtype[],ARRAY[hot::text,p_id::text],false) AS q(rev bigint);
    ELSE
        SELECT q.doc INTO old_doc FROM splitjson._query(format('SELECT splitjson.restore(cold,%s) FROM %s WHERE id=$1',splitjson._hot_array(m.paths),m.storage_name),
            ARRAY['bigint']::regtype[],ARRAY[p_id::text],false) AS q(doc jsonb);
        new_doc:=splitjson._apply_patch_doc(old_doc,p_patch);
        IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_patch) e WHERE e->>'op'<>'test') THEN
            PERFORM splitjson._save(m.storage_name,p_id,new_doc,m.paths);
            SELECT q.rev INTO revision FROM splitjson._query(format('SELECT row_revision FROM %s WHERE id=$1',m.storage_name),
                ARRAY['bigint']::regtype[],ARRAY[p_id::text],false) AS q(rev bigint);
        END IF;
    END IF;
    RETURN splitjson._token(m.layout_epoch,p_id,revision);
END $$;
REVOKE ALL ON FUNCTION splitjson.apply_patch(regclass,bigint,jsonb,text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION splitjson._merge_patch(p_doc jsonb,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog, pg_temp
AS $$
DECLARE result jsonb; key text; value jsonb; prior jsonb;
BEGIN
    IF jsonb_typeof(p_patch)<>'object' THEN RETURN p_patch; END IF;
    result:=CASE WHEN jsonb_typeof(p_doc)='object' THEN p_doc ELSE '{}'::jsonb END;
    FOR key,value IN SELECT e.key,e.value FROM jsonb_each(p_patch) AS e(key,value) LOOP
        IF value='null'::jsonb THEN result:=result-key;
        ELSE prior:=result->key; result:=jsonb_set(result,ARRAY[key],splitjson._merge_patch(prior,value),true); END IF;
    END LOOP;
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION splitjson.merge_patch(p_table regclass,p_id bigint,p_patch jsonb,p_expected_revision text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; old_doc jsonb; new_doc jsonb; revision bigint; affected bigint;
BEGIN
    IF p_id IS NULL OR p_patch IS NULL THEN RAISE EXCEPTION 'id and patch must not be NULL' USING ERRCODE='22023'; END IF;
    m:=splitjson._lookup(p_table,'UPDATE');
    SELECT q.doc,q.rev INTO old_doc,revision FROM splitjson._query(format('SELECT splitjson.restore(cold,%s),row_revision FROM %s WHERE id=$1 FOR UPDATE',splitjson._hot_array(m.paths),m.storage_name),
        ARRAY['bigint']::regtype[],ARRAY[p_id::text],false) AS q(doc jsonb,rev bigint);
    GET DIAGNOSTICS affected=ROW_COUNT; IF affected=0 THEN RETURN NULL; END IF;
    IF p_expected_revision IS NOT NULL AND splitjson._token_revision(p_expected_revision,m.layout_epoch,p_id)<>revision THEN RAISE EXCEPTION 'stale or invalid revision token' USING ERRCODE='40001'; END IF;
    new_doc:=splitjson._merge_patch(old_doc,p_patch);
    IF new_doc IS NOT DISTINCT FROM old_doc THEN RETURN splitjson._token(m.layout_epoch,p_id,revision); END IF;
    PERFORM splitjson._save(m.storage_name,p_id,new_doc,m.paths);
    SELECT q.value INTO revision FROM splitjson._query(format('SELECT row_revision FROM %s WHERE id=$1',m.storage_name),
        ARRAY['bigint']::regtype[],ARRAY[p_id::text],false) AS q(value bigint);
    RETURN splitjson._token(m.layout_epoch,p_id,revision);
END $$;
REVOKE ALL ON FUNCTION splitjson.merge_patch(regclass,bigint,jsonb,text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION splitjson.upsert_document(p_table regclass,p_id bigint,p_doc jsonb,p_business jsonb DEFAULT '{}')
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; n integer; key text; cols text:='id,cold'; vals text:='$1,splitjson.pack($2,'; updates text:='cold=EXCLUDED.cold'; revision bigint; supplied boolean;
BEGIN
    IF p_id IS NULL OR p_doc IS NULL OR p_business IS NULL OR jsonb_typeof(p_business)<>'object' THEN RAISE EXCEPTION 'id, document and business object must be non-NULL' USING ERRCODE='22023'; END IF;
    m:=splitjson._lookup(p_table,'INSERT');
    PERFORM splitjson._lookup(p_table,'UPDATE');
    IF NOT has_column_privilege(splitjson._caller(),p_table,'id','INSERT') THEN RAISE EXCEPTION 'id INSERT permission required' USING ERRCODE='42501'; END IF;
    vals:=vals||quote_literal(m.paths::text)||'::jsonb)';
    FOR key IN SELECT jsonb_object_keys(p_business) LOOP IF NOT (m.business_columns ? key) THEN RAISE EXCEPTION 'unknown business column: %',key USING ERRCODE='22023'; END IF; END LOOP;
    FOR n IN 1..jsonb_array_length(m.paths) LOOP cols:=cols||format(',hot_%s',n); vals:=vals||format(',(splitjson.slots($2,%L::jsonb))[%s]',m.paths::text,n); updates:=updates||format(',hot_%s=EXCLUDED.hot_%s',n,n); END LOOP;
    n:=0;
    FOR key IN SELECT e.key FROM jsonb_each_text(m.business_columns) AS e(key,value) ORDER BY e.key COLLATE "C" LOOP
        n:=n+1; supplied:=p_business ? key;
        IF supplied AND (NOT has_column_privilege(splitjson._caller(),p_table,key,'INSERT') OR NOT has_column_privilege(splitjson._caller(),p_table,key,'UPDATE')) THEN
            RAISE EXCEPTION 'business INSERT/UPDATE permission required' USING ERRCODE='42501'; END IF;
        IF supplied THEN cols:=cols||format(',extra_%s',n); vals:=vals||format(',((jsonb_populate_record(NULL::%s,$3)).%I)',m.view_name,key); updates:=updates||format(',extra_%s=EXCLUDED.extra_%s',n,n); END IF;
    END LOOP;
    PERFORM splitjson._lookup(p_table,'UPDATE');
    SELECT q.rev INTO revision FROM splitjson._query(format('INSERT INTO %s(%s) VALUES(%s) ON CONFLICT(id) DO UPDATE SET %s RETURNING row_revision',m.storage_name,cols,vals,updates),
        ARRAY['bigint','jsonb','jsonb']::regtype[],ARRAY[p_id::text,p_doc::text,p_business::text],false) AS q(rev bigint);
    RETURN splitjson._token(m.layout_epoch,p_id,revision);
END $$;
REVOKE ALL ON FUNCTION splitjson.upsert_document(regclass,bigint,jsonb,jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION splitjson.find_ids_range(p_table regclass,p_path text[],p_kind text,p_lower jsonb DEFAULT NULL,p_upper jsonb DEFAULT NULL,
                                                    p_include_lower boolean DEFAULT true,p_include_upper boolean DEFAULT true,p_collation name DEFAULT NULL)
RETURNS SETOF bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog, pg_temp
AS $$
DECLARE m splitjson._tables%ROWTYPE; candidates integer[]; slot integer; expr text; condition text:='true'; lower_value text; upper_value text; json_kind text;
BEGIN
    IF p_path IS NULL OR p_kind IS NULL OR p_include_lower IS NULL OR p_include_upper IS NULL THEN RAISE EXCEPTION 'range arguments must not be NULL' USING ERRCODE='22023'; END IF;
    m:=splitjson._lookup(p_table,'SELECT'); candidates:=splitjson._path_candidates(m.paths,p_path);
    IF cardinality(candidates)<>1 OR p_kind NOT IN ('numeric','boolean','text') THEN RAISE EXCEPTION 'range path and kind must identify one typed slot' USING ERRCODE='22023'; END IF;
    IF p_kind='numeric' THEN expr:='(hot_'||candidates[1]||' #>> ''{}'')::numeric'; json_kind:='number';
    ELSIF p_kind='boolean' THEN expr:='(hot_'||candidates[1]||' #>> ''{}'')::boolean'; json_kind:='boolean';
    ELSE expr:='(hot_'||candidates[1]||' #>> ''{}'')'; json_kind:='string'; END IF;
    IF p_lower IS NOT NULL THEN IF jsonb_typeof(p_lower)<>json_kind THEN RAISE EXCEPTION 'lower bound has wrong JSON type' USING ERRCODE='22023'; END IF; lower_value:=p_lower #>> '{}'; condition:=condition||format(' AND jsonb_typeof(hot_%s)=%L AND %s %s $1%s',candidates[1],json_kind,expr,CASE WHEN p_include_lower THEN '>=' ELSE '>' END,CASE WHEN p_kind='numeric' THEN '::numeric' WHEN p_kind='boolean' THEN '::boolean' ELSE '' END); END IF;
    IF p_upper IS NOT NULL THEN IF jsonb_typeof(p_upper)<>json_kind THEN RAISE EXCEPTION 'upper bound has wrong JSON type' USING ERRCODE='22023'; END IF; upper_value:=p_upper #>> '{}'; condition:=condition||format(' AND jsonb_typeof(hot_%s)=%L AND %s %s $2%s',candidates[1],json_kind,expr,CASE WHEN p_include_upper THEN '<=' ELSE '<' END,CASE WHEN p_kind='numeric' THEN '::numeric' WHEN p_kind='boolean' THEN '::boolean' ELSE '' END); END IF;
    RETURN QUERY SELECT id FROM splitjson._query(format('SELECT id FROM %s WHERE %s',m.storage_name,condition),
        ARRAY['text','text']::regtype[],ARRAY[lower_value,upper_value],true) AS q(id bigint);
END $$;
REVOKE ALL ON FUNCTION splitjson.find_ids_range(regclass,text[],text,jsonb,jsonb,boolean,boolean,name) FROM PUBLIC;

