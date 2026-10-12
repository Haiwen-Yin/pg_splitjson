-- New internal helpers revoke default ACLs as well as PUBLIC. Existing public
-- API grants survive replacement; grant_access explicitly adds new APIs.
DO $$ DECLARE signature text; grantee text; BEGIN
    FOR signature,grantee IN SELECT p.oid::regprocedure::text,
        CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee JOIN pg_depend d ON d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e'
        JOIN pg_extension e ON e.oid=d.refobjid AND d.refclassid='pg_extension'::regclass
        WHERE e.extname='pg_splitjson' AND a.grantee<>p.proowner AND
        (left(p.proname,1)='_' OR p.proname IN ('policy_field','row_revision','set_fields_if_revision','apply_patch','merge_patch',
        'fence_writes','prepare_online_migration','migration_status','abort_migration','mark_migration_state','complete_migration','prepare_replica','replication_status','takeover_replica','import_manifest','import_row','set_business_collation','reinitialize_table','upsert_document','find_ids_range','enable_rls','set_policy','drop_policy','create_partitioned_table','create_partition','attach_partition',
        'declare_path_type','register_path_index','detach_partition','partition_index_ddl','migration_plan','migrate_layout','export_manifest','export_rows','replication_manifest','replication_ddl','prepare_replica_manifest','register_replica_subscription','stop_replica'))
    LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s CASCADE',signature,grantee); END LOOP;
    PERFORM splitjson._secure_relation('splitjson._leaves');
    PERFORM splitjson._secure_relation('splitjson._policies');
    PERFORM splitjson._secure_relation('splitjson._field_checks');
    PERFORM splitjson._secure_relation('splitjson._slot_types');
    PERFORM splitjson._secure_relation('splitjson._jobs');
    PERFORM splitjson._secure_relation('splitjson._migration_rows');
    PERFORM splitjson._secure_relation('splitjson._replicas');
    PERFORM splitjson._secure_relation('splitjson._job_id_seq');
    PERFORM splitjson._secure_relation('splitjson._path_indexes');
END $$;
ALTER EVENT TRIGGER splitjson_ddl_end ENABLE;
ALTER EVENT TRIGGER splitjson_sql_drop ENABLE;
