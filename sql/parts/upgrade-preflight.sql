
-- Reject obsolete same-version prototypes before changing any catalog objects.
DO $$
BEGIN
    IF to_regprocedure('splitjson.create_table(text,jsonb,jsonb)') IS NULL OR
       to_regprocedure('splitjson.create_path_index(regclass,text,jsonb,text)') IS NULL OR
       to_regprocedure('splitjson.restore(splitjson.cold,jsonb[],jsonb)') IS NULL OR
       NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='splitjson._tables'::regclass
                  AND attname='business_columns' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'unsupported historical 0.1.0 build; use logical migration'
            USING ERRCODE='0A000';
    END IF;
    IF        (SELECT md5(prosrc) FROM pg_proc WHERE oid='splitjson.create_table(text,jsonb,jsonb)'::regprocedure) IS DISTINCT FROM 'fd2b7dfd1550130ddcaa66cafffcd5d7' OR
       (SELECT md5(prosrc) FROM pg_proc WHERE oid='splitjson._lookup(regclass,text)'::regprocedure) IS DISTINCT FROM '90fd80728c794597b11e7fb217973de1' OR
       (SELECT md5(prosrc) FROM pg_proc WHERE oid='splitjson._view_write()'::regprocedure) IS DISTINCT FROM '12e35122fe09d717bf05c99e2cc93287' OR
       (SELECT md5(prosrc) FROM pg_proc WHERE oid='splitjson.set_fields(regclass,bigint,jsonb,boolean)'::regprocedure) IS DISTINCT FROM '4c39cc3d4cb95e4075094bb5fec09b7e' THEN
        RAISE EXCEPTION 'unrecognized 0.1.0 function definitions; use logical migration' USING ERRCODE='0A000';
    END IF;
END $$;
