\set ON_ERROR_STOP on
SELECT setseed(0.314159);
SELECT splitjson.create_table('public.random_docs','[["x"],["a",0,"n"],["a","0","n"],["hot"]]');
DO $$
DECLARE doc jsonb; expected jsonb; actual jsonb; path text[]; paths jsonb;
        value jsonb; mode integer; native_state text; split_state text; cases integer:=0;
BEGIN
    paths := '[["x"],["x","bad"],["a","0","n"],["a","-1","n"],["a","00","n"],
               ["a","bad"],["a","0"],["a","99"],["hot","-1"],["hot","0","n"],
               ["hot","child"],["cold"],["new","child"]]';
    FOR sample IN 1..100 LOOP
        doc:=jsonb_build_object('x',sample,'a',CASE WHEN random()<0.5 THEN
            '[{"n":0},{"n":1}]'::jsonb ELSE '{"0":{"n":2}}'::jsonb END,
            'hot',CASE WHEN random()<0.5 THEN '[{"n":1},null,3]'::jsonb ELSE '{"child":1}'::jsonb END,
            'cold',md5(sample::text));
        INSERT INTO random_docs VALUES(sample,doc);
        FOR operation IN 1..50 LOOP
            path:=ARRAY(SELECT jsonb_array_elements_text(paths->floor(random()*jsonb_array_length(paths))::integer));
            value:=CASE floor(random()*5)::integer WHEN 0 THEN 'null'::jsonb
                WHEN 1 THEN to_jsonb(operation) WHEN 2 THEN to_jsonb(md5(operation::text))
                WHEN 3 THEN jsonb_build_array(operation,NULL) ELSE jsonb_build_object('n',operation) END;
            mode:=floor(random()*3)::integer; native_state:=NULL; split_state:=NULL;
            BEGIN
                IF mode=0 THEN expected:=doc #- path;
                ELSIF mode=1 THEN expected:=jsonb_set(doc,path,value,true);
                ELSE expected:=jsonb_set(jsonb_set(doc,path,value,true),'{x}',to_jsonb(operation),true); END IF;
            EXCEPTION WHEN OTHERS THEN native_state:=SQLSTATE; END;
            BEGIN
                IF mode=0 THEN PERFORM splitjson.delete_field('random_docs',sample,path);
                ELSIF mode=1 THEN PERFORM splitjson.set_field('random_docs',sample,path,value);
                ELSE PERFORM splitjson.set_fields('random_docs',sample,jsonb_build_array(
                    jsonb_build_object('path',to_jsonb(path),'value',value),
                    jsonb_build_object('path',ARRAY['x'],'value',operation))); END IF;
            EXCEPTION WHEN OTHERS THEN split_state:=SQLSTATE; END;
            PERFORM assert_true(native_state IS NOT DISTINCT FROM split_state,'random native SQLSTATE equivalence');
            SELECT d.doc INTO actual FROM random_docs d WHERE id=sample;
            IF native_state IS NULL THEN PERFORM assert_true(actual=expected,'random native result equivalence'); doc:=expected;
            ELSE PERFORM assert_true(actual=doc,'random operation rollback'); END IF;
            cases:=cases+1;
        END LOOP;
    END LOOP;
    RAISE NOTICE 'randomized differential cases: %',cases;
END$$;
SELECT splitjson.check_table('random_docs',true);
SELECT '5000 seeded differential operations passed' AS result;
