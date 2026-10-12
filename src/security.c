/* Copyright 2026 PG SplitJSON contributors
 * SPDX-License-Identifier: Apache-2.0
 */

/* ACL authorization is deliberately separate from RLS identity. Native rewrite
 * runs with the effective caller. Only then may the registered view's storage
 * permission record use its owner. No user expression executes as that owner.
 * Internal SQL has a one-prepare capability, consumed before SPI execution. */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "catalog/namespace.h"
#include "catalog/pg_extension.h"
#include "catalog/pg_type_d.h"
#include "catalog/pg_type.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_class.h"
#include "catalog/partition.h"
#include "commands/extension.h"
#include "commands/trigger.h"
#include "access/htup_details.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "nodes/nodeFuncs.h"
#include "nodes/readfuncs.h"
#include "parser/analyze.h"
#include "parser/parse_relation.h"
#include "parser/parse_func.h"
#include "parser/parsetree.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/jsonb.h"
#include "utils/plancache.h"
#include "utils/acl.h"
#include "utils/array.h"
#include "utils/memutils.h"
#include "utils/syscache.h"
#include "utils/snapmgr.h"
#include "utils/partcache.h"
#include "security.h"

extern Datum pg_splitjson_pack(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(pg_splitjson_partition_bound);
Datum
pg_splitjson_partition_bound(PG_FUNCTION_ARGS)
{
    HeapTuple tuple=SearchSysCache1(RELOID,PG_GETARG_DATUM(0));
    bool isnull;
    Datum raw;
    PartitionBoundSpec *bound;
    StringInfoData out;
    int i;
    if (!HeapTupleIsValid(tuple)) elog(ERROR,"partition is missing");
    raw=SysCacheGetAttr(RELOID,tuple,Anum_pg_class_relpartbound,&isnull);
    if (isnull) elog(ERROR,"relation is not a partition");
    bound=(PartitionBoundSpec *)stringToNode(TextDatumGetCString(raw));
    ReleaseSysCache(tuple);
    if (!IsA(bound,PartitionBoundSpec) || bound->is_default)
        ereport(ERROR,(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),errmsg("unsupported managed partition bound")));
    initStringInfo(&out);
    if (bound->strategy==PARTITION_STRATEGY_HASH)
        appendStringInfo(&out,"{\"modulus\":%d,\"remainder\":%d}",bound->modulus,bound->remainder);
    else if (bound->strategy==PARTITION_STRATEGY_RANGE)
    {
        appendStringInfoChar(&out,'{');
        for (i=0;i<2;i++)
        {
            List *items=i==0 ? bound->lowerdatums : bound->upperdatums;
            PartitionRangeDatum *range;
            if (list_length(items)!=1) elog(ERROR,"managed partition key must be id only");
            range=linitial_node(PartitionRangeDatum,items);
            appendStringInfo(&out,"%s\"%s\":",i==0 ? "" : ",",i==0 ? "from" : "to");
            if (range->kind!=PARTITION_RANGE_DATUM_VALUE) appendStringInfoString(&out,"null");
            else
            {
                Const *value=(Const *)range->value;
                if (!IsA(value,Const) || value->consttype!=INT8OID || value->constisnull)
                    elog(ERROR,"managed partition bound must be bigint");
                appendStringInfo(&out,INT64_FORMAT,DatumGetInt64(value->constvalue));
            }
        }
        appendStringInfoChar(&out,'}');
    }
    else elog(ERROR,"unsupported partition strategy");
    PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in,CStringGetDatum(out.data)));
}

typedef struct PrepareCapability
{
    Oid caller;
    Oid storage;
    bool analyzed;
    bool authorized;
    struct PrepareCapability *previous;
} PrepareCapability;

static PrepareCapability *capability = NULL;
static post_parse_analyze_hook_type previous_analyze = NULL;

typedef struct EntryContext
{
    Oid caller;
    Oid view;
    bool admin;
    struct EntryContext *previous;
} EntryContext;

static EntryContext *entry = NULL;

Oid
splitjson_entry_caller(void)
{
    return entry ? entry->caller : GetUserId();
}

Oid
splitjson_extension_owner(void)
{
    Oid extension = get_extension_oid("pg_splitjson", true);
    HeapTuple tuple;
    Oid owner;

    if (!OidIsValid(extension))
        return InvalidOid;
    tuple = SearchSysCache1(EXTENSIONOID, ObjectIdGetDatum(extension));
    if (!HeapTupleIsValid(tuple))
        return InvalidOid;
    owner = ((Form_pg_extension) GETSTRUCT(tuple))->extowner;
    ReleaseSysCache(tuple);
    return owner;
}

/* Names are stable across dump/restore. The caller never reads the registry.
 * Canonical definition, owner and barrier checks deny forged projections. */
static bool
registered_view(Oid view, Oid storage)
{
    Oid owner = splitjson_extension_owner();
    Oid saved_user;
    int saved_context;
    bool result = false;
    Oid types[2] = {OIDOID, OIDOID};
    Datum values[2] = {ObjectIdGetDatum(view), ObjectIdGetDatum(storage)};

    if (!OidIsValid(owner))
        return false;
    GetUserIdAndSecContext(&saved_user, &saved_context);
    PG_TRY();
    {
        bool isnull;

        SetUserIdAndSecContext(owner, saved_context | SECURITY_LOCAL_USERID_CHANGE);
        if (SPI_connect() != SPI_OK_CONNECT)
            elog(ERROR, "SPI_connect failed");
        if (SPI_execute_with_args(
            "SELECT EXISTS (SELECT 1 FROM splitjson._tables m "
            "JOIN pg_catalog.pg_class v ON v.oid=$1 "
            "JOIN pg_catalog.pg_class s ON s.oid=$2 "
            "WHERE pg_catalog.to_regclass(m.view_name)=$1 "
            "AND pg_catalog.to_regclass(m.storage_name)=$2 "
            "AND v.relkind='v' AND v.relowner=s.relowner "
            "AND v.relowner=(SELECT extowner FROM pg_catalog.pg_extension WHERE extname='pg_splitjson') "
            "AND v.reloptions @> ARRAY['security_barrier=true','security_invoker=true'] "
            "AND m.view_definition=pg_catalog.pg_get_viewdef(v.oid,true) "
            "AND s.relnamespace=pg_catalog.to_regnamespace('splitjson_storage'))",
            2, types, values, NULL, true, 1) != SPI_OK_SELECT)
            elog(ERROR, "managed view authorization check failed");
        result = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
        SPI_finish();
        SetUserIdAndSecContext(saved_user, saved_context);
    }
    PG_CATCH();
    {
        SetUserIdAndSecContext(saved_user, saved_context);
        PG_RE_THROW();
    }
    PG_END_TRY();
    return result;
}

static bool authorize_walker(Node *node, void *context);

void
splitjson_authorize_query(Query *query)
{
    Oid private_namespace = get_namespace_oid("splitjson_storage", true);
    ListCell *lc;
    PrepareCapability *direct = NULL;

    check_stack_depth();
    if (!OidIsValid(private_namespace))
        return;
    /* Consume the direct authorization before recursive policy planning or
     * constant folding can execute user code. Nested Queries never inherit it. */
    if (capability && capability->analyzed && !capability->authorized)
    {
        direct = capability;
        capability->authorized = true;
    }
    foreach(lc, query->rtable)
    {
        RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);

        if (direct && rte->rtekind == RTE_RELATION &&
            rte->relid == direct->storage && rte->perminfoindex != 0 &&
            get_rel_namespace(rte->relid) == private_namespace)
        {
            RTEPermissionInfo *perms = getRTEPermissionInfo(query->rteperminfos, rte);

            perms->checkAsUser = splitjson_extension_owner();
        }
        if (rte->rtekind == RTE_SUBQUERY && rte->subquery)
        {
            Query *child = rte->subquery;

            if (OidIsValid(rte->relid) && rte->security_barrier && rte->perminfoindex != 0 &&
                child->commandType == CMD_SELECT && child->jointree &&
                list_length(child->jointree->fromlist) == 1 &&
                IsA(linitial(child->jointree->fromlist), RangeTblRef))
            {
                RangeTblRef *ref = linitial_node(RangeTblRef, child->jointree->fromlist);
                RangeTblEntry *storage = rt_fetch(ref->rtindex, child->rtable);

                if (storage->rtekind == RTE_RELATION && storage->perminfoindex != 0 &&
                    get_rel_namespace(storage->relid) == private_namespace &&
                    registered_view(rte->relid, storage->relid))
                {
                    RTEPermissionInfo *perms = getRTEPermissionInfo(child->rteperminfos, storage);

                    /* Do not touch securityQuals, hasRowSecurity or check options. */
                    perms->checkAsUser = splitjson_extension_owner();
                }
            }
        }
    }
    query_tree_walker(query, authorize_walker, NULL, 0);
}

static bool
authorize_walker(Node *node, void *context)
{
    if (node == NULL)
        return false;
    if (IsA(node, Query))
    {
        splitjson_authorize_query((Query *) node);
        return false;
    }
    return expression_tree_walker(node, authorize_walker, context);
}

static void
splitjson_analyzed(ParseState *state, Query *query, JumbleState *jstate)
{
    if (previous_analyze)
        previous_analyze(state, query, jstate);
    if (capability && !capability->analyzed)
    {
        Oid saved_user;
        int saved_context;

        GetUserIdAndSecContext(&saved_user, &saved_context);
        /* Namespace resolution has finished. RLS rewrite and planning now run
         * as the caller, including role matching and row_security=off. */
        capability->analyzed = true;
        SetUserIdAndSecContext(capability->caller, saved_context | SECURITY_LOCAL_USERID_CHANGE);
    }
}

SPIPlanPtr
splitjson_prepare_caller(const char *sql, int nargs, Oid *types, Oid caller, Oid storage)
{
    PrepareCapability local = {caller, storage, false, false, capability};
    Oid saved_user;
    int saved_context;
    SPIPlanPtr plan = NULL;

    GetUserIdAndSecContext(&saved_user, &saved_context);
    PG_TRY();
    {
        capability = &local;
        SetUserIdAndSecContext(splitjson_extension_owner(), saved_context | SECURITY_LOCAL_USERID_CHANGE);
        plan = SPI_prepare_cursor(sql, nargs, types, CURSOR_OPT_GENERIC_PLAN);
        if (plan == NULL || !local.analyzed)
            elog(ERROR, "could not prepare managed statement");
        /* SPI_prepare defers planning until execution. Force a generic plan
         * while the one-statement capability is still live, then release its
         * reference before any user expression may run. */
        {
            CachedPlan *cached = SPI_plan_get_cached_plan(plan);

            if (cached == NULL)
                elog(ERROR, "could not plan managed statement");
            ReleaseCachedPlan(cached, NULL);
        }
        capability = local.previous;
        SetUserIdAndSecContext(saved_user, saved_context);
    }
    PG_CATCH();
    {
        capability = local.previous;
        SetUserIdAndSecContext(saved_user, saved_context);
        PG_RE_THROW();
    }
    PG_END_TRY();
    return plan;
}

void
splitjson_security_init(void)
{
    previous_analyze = post_parse_analyze_hook;
    post_parse_analyze_hook = splitjson_analyzed;
}

void
splitjson_security_fini(void)
{
    if (post_parse_analyze_hook == splitjson_analyzed)
        post_parse_analyze_hook = previous_analyze;
}

/* Every public data entry is SECURITY INVOKER. fmgr changes identity only
 * after the entry's effective role has been captured here. Internal helper
 * execution remains privileged for metadata, but all data SQL goes through
 * _query(), which plans and executes under this captured role. */
static Datum
call_implementation(FunctionCallInfo fcinfo, bool admin, bool trigger)
{
    EntryContext local;
    Oid function = fcinfo->flinfo->fn_oid;
    HeapTuple tuple = SearchSysCache1(PROCOID, ObjectIdGetDatum(function));
    Form_pg_proc proc;
    Oid implementation;
    FmgrInfo info;
    LOCAL_FCINFO(inner, FUNC_MAX_ARGS);
    Datum result = (Datum) 0;
    char *name;
    int i;
    bool migration;

    if (!HeapTupleIsValid(tuple))
        elog(ERROR, "public function is missing");
    proc = (Form_pg_proc) GETSTRUCT(tuple);
    if (proc->prosecdef)
        elog(ERROR, "managed C entry must be SECURITY INVOKER");
    migration = strcmp(NameStr(proc->proname),"migrate_layout")==0;
    name = psprintf("_api_%s", NameStr(proc->proname));
    implementation = LookupFuncName(list_make2(makeString("splitjson"), makeString(name)),
                                    proc->pronargs, proc->proargtypes.values, false);
    ReleaseSysCache(tuple);
    local.caller = GetUserId();
    local.previous = entry;
    local.admin = admin || migration;
    local.view = InvalidOid;
    if (admin && local.caller != splitjson_extension_owner())
        ereport(ERROR, (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE), errmsg("management requires the extension installer")));
    if (trigger)
    {
        if (!CALLED_AS_TRIGGER(fcinfo))
            elog(ERROR, "not called as a trigger");
        local.view = RelationGetRelid(((TriggerData *) fcinfo->context)->tg_relation);
    }
    else if (fcinfo->nargs > 0 && !PG_ARGISNULL(0) && get_fn_expr_argtype(fcinfo->flinfo,0)==REGCLASSOID)
        local.view = PG_GETARG_OID(0);
    fmgr_info(implementation, &info);
    InitFunctionCallInfoData(*inner, &info, fcinfo->nargs, fcinfo->fncollation, fcinfo->context, fcinfo->resultinfo);
    for (i = 0; i < fcinfo->nargs; i++)
        inner->args[i] = fcinfo->args[i];
    PG_TRY();
    {
        entry = &local;
        result = FunctionCallInvoke(inner);
        fcinfo->isnull = inner->isnull;
        entry = local.previous;
    }
    PG_CATCH();
    {
        entry = local.previous;
        PG_RE_THROW();
    }
    PG_END_TRY();
    return result;
}

PG_FUNCTION_INFO_V1(pg_splitjson_data_entry);
Datum
pg_splitjson_data_entry(PG_FUNCTION_ARGS)
{
    return call_implementation(fcinfo, false, false);
}

PG_FUNCTION_INFO_V1(pg_splitjson_admin_entry);
Datum
pg_splitjson_admin_entry(PG_FUNCTION_ARGS)
{
    return call_implementation(fcinfo, true, false);
}

PG_FUNCTION_INFO_V1(pg_splitjson_view_entry);
Datum
pg_splitjson_view_entry(PG_FUNCTION_ARGS)
{
    return call_implementation(fcinfo, false, true);
}

PG_FUNCTION_INFO_V1(pg_splitjson_caller);
Datum
pg_splitjson_caller(PG_FUNCTION_ARGS)
{
    PG_RETURN_DATUM(DirectFunctionCall1(namein, CStringGetDatum(GetUserNameFromId(splitjson_entry_caller(), false))));
}

PG_FUNCTION_INFO_V1(pg_splitjson_ddl_scope);
Datum
pg_splitjson_ddl_scope(PG_FUNCTION_ARGS)
{
    PG_RETURN_BOOL(entry && entry->admin);
}

/* Private, non-PUBLIC executor. Params use PostgreSQL text output/input, so
 * array dimensions, domains, typmods and native composites are preserved.
 * The result descriptor is provided by the private implementation, and native
 * Datums are materialized without a JSON/text round-trip of returned data. */
PG_FUNCTION_INFO_V1(pg_splitjson_query);
Datum
pg_splitjson_query(PG_FUNCTION_ARGS)
{
    char *sql = text_to_cstring(PG_GETARG_TEXT_PP(0));
    ArrayType *type_array = PG_GETARG_ARRAYTYPE_P(1);
    ArrayType *value_array = PG_GETARG_ARRAYTYPE_P(2);
    bool read_only = PG_GETARG_BOOL(3);
    Oid storage;
    bool isnull;
    Datum *type_values;
    Datum *text_values;
    bool *type_nulls;
    bool *text_nulls;
    int ntypes;
    int nvalues;
    Oid *types;
    Datum *values;
    char *nulls;
    Oid saved_user;
    int saved_context;
    SPIPlanPtr plan;
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    uint64 row;
    int i;

    if (entry == NULL || !OidIsValid(entry->view))
        ereport(ERROR, (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE), errmsg("managed query requires a trusted data entry")));
    InitMaterializedSRF(fcinfo, MAT_SRF_USE_EXPECTED_DESC);
    deconstruct_array(type_array, REGTYPEOID, 4, true, TYPALIGN_INT, &type_values, &type_nulls, &ntypes);
    deconstruct_array(value_array, TEXTOID, -1, false, TYPALIGN_INT, &text_values, &text_nulls, &nvalues);
    if (ntypes != nvalues || ntypes > FUNC_MAX_ARGS)
        elog(ERROR, "managed query parameter mismatch");
    types = palloc(sizeof(Oid) * ntypes);
    values = palloc(sizeof(Datum) * ntypes);
    nulls = palloc(ntypes);
    if (SPI_connect() != SPI_OK_CONNECT)
        elog(ERROR, "SPI_connect failed");
    {
        Oid meta_type = OIDOID;
        Datum meta_value = ObjectIdGetDatum(entry->view);

        if (SPI_execute_with_args("SELECT storage_name::regclass::oid FROM splitjson._tables "
                                  "WHERE view_name::regclass=$1", 1, &meta_type, &meta_value, NULL, true, 1) != SPI_OK_SELECT ||
            SPI_processed != 1)
            ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("relation is not a registered managed view")));
        storage = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
    }
    GetUserIdAndSecContext(&saved_user, &saved_context);
    PG_TRY();
    {
        /* Param input and policy/user expressions execute as actual caller. */
        SetUserIdAndSecContext(entry->caller, saved_context | SECURITY_LOCAL_USERID_CHANGE);
        for (i = 0; i < ntypes; i++)
        {
            Oid input;
            Oid io_param;

            if (type_nulls[i])
                elog(ERROR, "NULL managed parameter type");
            types[i] = DatumGetObjectId(type_values[i]);
            nulls[i] = text_nulls[i] ? 'n' : ' ';
            getTypeInputInfo(types[i], &input, &io_param);
            values[i] = OidInputFunctionCall(input, text_nulls[i] ? NULL : TextDatumGetCString(text_values[i]), io_param, -1);
        }
        plan = splitjson_prepare_caller(sql, ntypes, types, entry->caller, storage);
        if (SPI_execute_plan(plan, values, nulls, read_only, 0) < 0 || SPI_tuptable == NULL)
            elog(ERROR, "managed statement must return rows");
        if (SPI_tuptable->tupdesc->natts != rsinfo->setDesc->natts)
            elog(ERROR, "managed result column count mismatch");
        for (i = 0; i < rsinfo->setDesc->natts; i++)
            if (TupleDescAttr(SPI_tuptable->tupdesc,i)->atttypid != TupleDescAttr(rsinfo->setDesc,i)->atttypid)
                elog(ERROR, "managed result column type mismatch");
        for (row = 0; row < SPI_processed; row++)
            tuplestore_puttuple(rsinfo->setResult, SPI_tuptable->vals[row]);
        SPI_freeplan(plan);
        SetUserIdAndSecContext(saved_user, saved_context);
        SPI_finish();
    }
    PG_CATCH();
    {
        SetUserIdAndSecContext(saved_user, saved_context);
        PG_RE_THROW();
    }
    PG_END_TRY();
    PG_RETURN_NULL();
}

/* Temporary lab gate entry: only created in tests/security_gate.sql. */
PG_FUNCTION_INFO_V1(pg_splitjson_security_gate);
Datum
pg_splitjson_security_gate(PG_FUNCTION_ARGS)
{
    Oid caller = GetUserId();
    Oid storage = PG_GETARG_OID(0);
    bool write = PG_GETARG_BOOL(1);
    char *sql;
    SPIPlanPtr plan;
    Datum result;
    bool isnull;
    Oid types[2] = {INT8OID, TEXTOID};
    Datum values[2] = {PG_GETARG_DATUM(2), PG_GETARG_DATUM(3)};

    if (!superuser_arg(splitjson_extension_owner()) ||
        get_rel_namespace(storage) != get_namespace_oid("splitjson_storage", false))
        elog(ERROR, "invalid gate installation");
    sql = psprintf(write ? "UPDATE %s SET extra_1=$2::name WHERE id=$1 RETURNING id" :
                   "SELECT id FROM %s WHERE id=$1", quote_qualified_identifier(
                   get_namespace_name(get_rel_namespace(storage)), get_rel_name(storage)));
    if (SPI_connect() != SPI_OK_CONNECT)
        elog(ERROR, "SPI_connect failed");
    plan = splitjson_prepare_caller(sql, 2, types, caller, storage);
    if (SPI_execute_plan(plan, values, NULL, !write, 0) < 0)
        elog(ERROR, "managed gate execution failed");
    if (SPI_processed == 0)
    {
        SPI_finish();
        PG_RETURN_NULL();
    }
    result = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
    SPI_finish();
    PG_RETURN_DATUM(result);
}

/* Diagnostic trigger, installed only by the lab gate. */
PG_FUNCTION_INFO_V1(pg_splitjson_security_gate_trigger);
Datum
pg_splitjson_security_gate_trigger(PG_FUNCTION_ARGS)
{
    TriggerData *trigger = (TriggerData *) fcinfo->context;
    Oid caller = GetUserId();
    Oid storage;
    Oid saved_user;
    int saved_context;
    Oid meta_types[1] = {OIDOID};
    Datum meta_values[1];
    HeapTuple tuple;
    bool isnull;
    Datum values[4];
    Oid types[4];
    char *sql;
    Jsonb *paths;
    SPIPlanPtr plan;

    if (!CALLED_AS_TRIGGER(fcinfo))
        elog(ERROR, "not called as trigger");
    meta_values[0] = ObjectIdGetDatum(RelationGetRelid(trigger->tg_relation));
    if (SPI_connect() != SPI_OK_CONNECT)
        elog(ERROR, "SPI_connect failed");
    GetUserIdAndSecContext(&saved_user, &saved_context);
    PG_TRY();
    {
        SetUserIdAndSecContext(splitjson_extension_owner(), saved_context | SECURITY_LOCAL_USERID_CHANGE);
        if (SPI_execute_with_args("SELECT storage_name::regclass::oid FROM splitjson._tables "
                                  "WHERE view_name::regclass=$1", 1, meta_types, meta_values, NULL, true, 1) != SPI_OK_SELECT ||
            SPI_processed != 1)
            elog(ERROR, "unregistered gate view");
        storage = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
        SetUserIdAndSecContext(saved_user, saved_context);
    }
    PG_CATCH();
    {
        SetUserIdAndSecContext(saved_user, saved_context);
        PG_RE_THROW();
    }
    PG_END_TRY();
    tuple = TRIGGER_FIRED_BY_UPDATE(trigger->tg_event) ? trigger->tg_newtuple : trigger->tg_trigtuple;
    values[0] = heap_getattr(tuple, 1, RelationGetDescr(trigger->tg_relation), &isnull);
    types[0] = INT8OID;
    types[1] = get_atttype(storage, 2);
    types[2] = JSONBOID;
    types[3] = NAMEOID;
    if (TRIGGER_FIRED_BY_DELETE(trigger->tg_event))
        sql = psprintf("DELETE FROM %s WHERE id=$1", quote_qualified_identifier(
                         get_namespace_name(get_rel_namespace(storage)), get_rel_name(storage)));
    else
    {
        Datum doc = heap_getattr(tuple, 2, RelationGetDescr(trigger->tg_relation), &isnull);

        if (isnull)
            ereport(ERROR, (errcode(ERRCODE_NOT_NULL_VIOLATION), errmsg("doc is required")));
        paths = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, CStringGetDatum("[[\"state\"]]")));
        values[1] = DirectFunctionCall2(pg_splitjson_pack, doc, JsonbPGetDatum(paths));
        values[2] = DirectFunctionCall2(jsonb_object_field, doc, CStringGetTextDatum("state"));
        values[3] = heap_getattr(tuple, 3, RelationGetDescr(trigger->tg_relation), &isnull);
        if (isnull)
            ereport(ERROR, (errcode(ERRCODE_NOT_NULL_VIOLATION), errmsg("tenant is required")));
        sql = psprintf(TRIGGER_FIRED_BY_INSERT(trigger->tg_event) ?
                       "INSERT INTO %s(id,cold,hot_1,extra_1) VALUES($1,$2,$3,$4)" :
                       "UPDATE %s SET cold=$2,hot_1=$3,extra_1=$4 WHERE id=$1",
                       quote_qualified_identifier(get_namespace_name(get_rel_namespace(storage)), get_rel_name(storage)));
    }
    plan = splitjson_prepare_caller(sql, TRIGGER_FIRED_BY_DELETE(trigger->tg_event) ? 1 : 4, types, caller, storage);
    if (SPI_execute_plan(plan, values, NULL, false, 0) < 0)
        elog(ERROR, "gate trigger failed");
    SPI_finish();
    PG_RETURN_POINTER(tuple);
}

/* Compile an expression in the public column namespace, then remap its Vars
 * to storage. The analyzed node tree, never a text/regex substitution, defines
 * the allowed policy language. Parsing does not execute policy expressions. */
#include "catalog/pg_namespace_d.h"
#include "catalog/pg_operator.h"
#include "nodes/makefuncs.h"
#include "parser/parser.h"
#include "utils/ruleutils.h"

typedef struct PolicyContext
{
    Oid view;
    Oid storage;
    Oid marker;
    Jsonb *paths;
} PolicyContext;

static void
policy_reject(void)
{
    ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                    errmsg("policy expression is outside the supported language")));
}

static void
policy_builtin(Oid function, bool operator)
{
    HeapTuple tuple = SearchSysCache1(PROCOID, ObjectIdGetDatum(function));
    Form_pg_proc proc;
    const char *name;
    bool allowed;

    if (!HeapTupleIsValid(tuple))
        policy_reject();
    proc = (Form_pg_proc) GETSTRUCT(tuple);
    name = NameStr(proc->proname);
    allowed = proc->pronamespace == PG_CATALOG_NAMESPACE &&
              proc->provolatile != PROVOLATILE_VOLATILE && !proc->prosecdef &&
              proc->prokind == PROKIND_FUNCTION && !proc->proretset;
    if (!operator)
        allowed = allowed &&
            (strcmp(name,"jsonb_typeof")==0 || strcmp(name,"lower")==0 ||
             strcmp(name,"upper")==0 || strcmp(name,"length")==0 ||
             strcmp(name,"abs")==0 || strcmp(name,"text")==0 ||
             strcmp(name,"name")==0 || strcmp(name,"numeric")==0 ||
             strcmp(name,"int8")==0 || strcmp(name,"int4")==0 ||
             strcmp(name,"bool")==0);
    ReleaseSysCache(tuple);
    if (!allowed)
        policy_reject();
}

static Node *
policy_expression(Node *node, PolicyContext *context)
{
    if (node == NULL)
        return NULL;
    check_stack_depth();
    if (IsA(node, Var))
    {
        Var *source = (Var *) node;
        Var *result;
        char *name;
        AttrNumber target;

        if (source->varno != 1 || source->varlevelsup != 0 || source->varattno <= 0)
            policy_reject();
        name = get_attname(context->view,source->varattno,false);
        if (strcmp(name,"doc")==0)
            policy_reject();
        target = source->varattno == 1 ? 1 : get_attnum(context->storage,psprintf("extra_%d",source->varattno-2));
        if (target == InvalidAttrNumber)
            policy_reject();
        result = copyObject(source);
        result->varattno = result->varattnosyn = target;
        return (Node *) result;
    }
    if (IsA(node, FuncExpr))
    {
        FuncExpr *function = (FuncExpr *) node;
        if (function->funcid == context->marker)
        {
            Const *path;
            int count = JsonContainerSize(&context->paths->root);
            int i;
            if (list_length(function->args) != 1 || !IsA(linitial(function->args),Const))
                policy_reject();
            path = linitial_node(Const,function->args);
            if (path->constisnull || path->consttype != JSONBOID)
                policy_reject();
            for (i=0; i<count; i++)
            {
                Jsonb *declared = DatumGetJsonbP(DirectFunctionCall2(jsonb_array_element,
                    JsonbPGetDatum(context->paths),Int32GetDatum(i)));
                if (compareJsonbContainers(&declared->root,&DatumGetJsonbP(path->constvalue)->root)==0)
                    return (Node *) makeVar(1,get_attnum(context->storage,psprintf("hot_%d",i+1)),
                                            JSONBOID,-1,InvalidOid,0);
            }
            policy_reject();
        }
        policy_builtin(function->funcid,false);
    }
    else if (IsA(node,OpExpr) || IsA(node,DistinctExpr) || IsA(node,NullIfExpr))
    {
        OpExpr *op = (OpExpr *) node;
        HeapTuple tuple = SearchSysCache1(OPEROID,ObjectIdGetDatum(op->opno));
        Form_pg_operator form;
        bool allowed;
        if (!HeapTupleIsValid(tuple)) policy_reject();
        form = (Form_pg_operator)GETSTRUCT(tuple);
        allowed = form->oprnamespace == PG_CATALOG_NAMESPACE;
        policy_builtin(form->oprcode,true);
        ReleaseSysCache(tuple);
        if (!allowed) policy_reject();
    }
    else if (IsA(node,ScalarArrayOpExpr))
    {
        ScalarArrayOpExpr *op=(ScalarArrayOpExpr *)node;
        policy_builtin(get_opcode(op->opno),true);
    }
    else if (IsA(node,SQLValueFunction))
    {
        SQLValueFunctionOp op=((SQLValueFunction *)node)->op;
        if (op != SVFOP_CURRENT_USER && op != SVFOP_SESSION_USER && op != SVFOP_CURRENT_ROLE)
            policy_reject();
    }
    else if (!(IsA(node,Const) || IsA(node,BoolExpr) || IsA(node,NullTest) ||
               IsA(node,BooleanTest) || IsA(node,RelabelType) || IsA(node,CoalesceExpr) ||
               IsA(node,CaseExpr) || IsA(node,CaseWhen) || IsA(node,CaseTestExpr) ||
               IsA(node,ArrayExpr) || IsA(node,CollateExpr) || IsA(node,List)))
        policy_reject();
    return expression_tree_mutator(node,policy_expression,context);
}

/* Reject untrusted type input/functions before parse analysis can resolve
 * constants. A raw expression must not alter the synthetic SELECT structure. */
static bool
policy_raw(Node *node, void *unused)
{
    if (node == NULL) return false;
    check_stack_depth();
    if (IsA(node,TypeCast))
    {
        TypeName *type=((TypeCast *)node)->typeName;
        const char *name=strVal(llast(type->names));
        if (list_length(type->names)>2 || (list_length(type->names)==2 &&
            strcmp(strVal(linitial(type->names)),"pg_catalog")!=0) || type->arrayBounds ||
            !(strcmp(name,"jsonb")==0 || strcmp(name,"text")==0 || strcmp(name,"numeric")==0 ||
              strcmp(name,"bool")==0 || strcmp(name,"int8")==0 || strcmp(name,"int4")==0 ||
              strcmp(name,"name")==0 || strcmp(name,"varchar")==0))
            policy_reject();
    }
    else if (IsA(node,FuncCall))
    {
        FuncCall *function=(FuncCall *)node;
        const char *name=strVal(llast(function->funcname));
        bool marker=list_length(function->funcname)==2 &&
            strcmp(strVal(linitial(function->funcname)),"splitjson")==0 && strcmp(name,"policy_field")==0;
        bool builtin=(list_length(function->funcname)==1 ||
            (list_length(function->funcname)==2 && strcmp(strVal(linitial(function->funcname)),"pg_catalog")==0)) &&
            (strcmp(name,"jsonb_typeof")==0 || strcmp(name,"lower")==0 || strcmp(name,"upper")==0 ||
             strcmp(name,"length")==0 || strcmp(name,"abs")==0);
        if ((!marker && !builtin) || function->agg_order || function->agg_filter || function->over ||
            function->agg_star || function->agg_distinct || function->func_variadic)
            policy_reject();
    }
    else if (IsA(node,ColumnRef))
    {
        ColumnRef *column=(ColumnRef *)node;
        if (list_length(column->fields)!=1 || !IsA(linitial(column->fields),String) ||
            strcmp(strVal(linitial(column->fields)),"doc")==0)
            policy_reject();
    }
    else if (!(IsA(node,A_Const) || IsA(node,A_Expr) || IsA(node,BoolExpr) ||
               IsA(node,SQLValueFunction) || IsA(node,NullTest) || IsA(node,BooleanTest) ||
               IsA(node,CaseExpr) || IsA(node,CaseWhen) || IsA(node,CoalesceExpr) ||
               IsA(node,A_ArrayExpr) || IsA(node,CollateClause) || IsA(node,TypeName) ||
               IsA(node,String) || IsA(node,Integer) || IsA(node,Float) || IsA(node,List)))
        policy_reject();
    return raw_expression_tree_walker(node,policy_raw,unused);
}

PG_FUNCTION_INFO_V1(pg_splitjson_policy_compile);
Datum
pg_splitjson_policy_compile(PG_FUNCTION_ARGS)
{
    PolicyContext context;
    char *expression = text_to_cstring(PG_GETARG_TEXT_PP(3));
    char *sql;
    List *raw;
    Query *query;
    TargetEntry *target;
    Node *mapped;
    Oid marker_type = JSONBOID;

    if (entry == NULL || !entry->admin)
        ereport(ERROR,(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),errmsg("policy compilation requires a trusted management entry")));
    context.view=PG_GETARG_OID(0);
    context.storage=PG_GETARG_OID(1);
    context.paths=PG_GETARG_JSONB_P(2);
    context.marker=LookupFuncName(list_make2(makeString("splitjson"),makeString("policy_field")),1,&marker_type,false);
    sql=psprintf("SELECT (%s) FROM %s",expression,quote_qualified_identifier(
        get_namespace_name(get_rel_namespace(context.view)),get_rel_name(context.view)));
    raw=raw_parser(sql,RAW_PARSE_DEFAULT);
    if (list_length(raw)!=1) policy_reject();
    {
        Node *statement=linitial_node(RawStmt,raw)->stmt;
        SelectStmt *select;
        ResTarget *result;
        if (!IsA(statement,SelectStmt)) policy_reject();
        select=(SelectStmt *)statement;
        if (list_length(select->targetList)!=1 || list_length(select->fromClause)!=1 ||
            !IsA(linitial(select->fromClause),RangeVar) || select->whereClause ||
            select->intoClause || select->groupClause || select->havingClause ||
            select->windowClause || select->sortClause || select->limitOffset ||
            select->limitCount || select->lockingClause || select->withClause ||
            select->op!=SETOP_NONE)
            policy_reject();
        result=linitial_node(ResTarget,select->targetList);
        policy_raw(result->val,NULL);
    }
    query=parse_analyze_fixedparams(linitial_node(RawStmt,raw),sql,NULL,0,NULL);
    if (query->commandType!=CMD_SELECT || list_length(query->targetList)!=1 ||
        list_length(query->rtable)!=1 || query->hasSubLinks || query->hasAggs ||
        query->hasWindowFuncs || query->cteList || query->setOperations ||
        query->jointree->quals || query->groupClause || query->sortClause ||
        query->limitCount || query->limitOffset)
        policy_reject();
    target=linitial_node(TargetEntry,query->targetList);
    if (exprType((Node *)target->expr)!=BOOLOID) policy_reject();
    mapped=policy_expression((Node *)target->expr,&context);
    PG_RETURN_TEXT_P(cstring_to_text(deparse_expression(mapped,
        deparse_context_for(get_rel_name(context.storage),context.storage),false,true)));
}

#include "access/table.h"
#include "catalog/pg_am_d.h"
#include "access/genam.h"
#include "utils/rel.h"
#include "utils/relcache.h"
#include "optimizer/optimizer.h"

PG_FUNCTION_INFO_V1(pg_splitjson_index_match);
Datum
pg_splitjson_index_match(PG_FUNCTION_ARGS)
{
    Oid index=PG_GETARG_OID(0);
    Oid storage=PG_GETARG_OID(1);
    char *expression=text_to_cstring(PG_GETARG_TEXT_PP(2));
    char *sql=psprintf("SELECT %s FROM %s",expression,quote_qualified_identifier(
        get_namespace_name(get_rel_namespace(storage)),get_rel_name(storage)));
    List *raw=raw_parser(sql,RAW_PARSE_DEFAULT);
    Query *query;
    Node *expected;
    Relation relation;
    List *expressions;
    bool result;
    AttrNumber column;

    if (entry==NULL || !entry->admin)
        ereport(ERROR,(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),errmsg("index verification requires a trusted management entry")));
    query=parse_analyze_fixedparams(linitial_node(RawStmt,raw),sql,NULL,0,NULL);
    expected=(Node *)linitial_node(TargetEntry,query->targetList)->expr;
    relation=index_open(index,AccessShareLock);
    expressions=RelationGetIndexExpressions(relation);
    column=relation->rd_index->indkey.values[0];
    result=relation->rd_index->indrelid==storage && relation->rd_index->indisvalid && relation->rd_index->indisready &&
        relation->rd_index->indnkeyatts==1 && RelationGetIndexPredicate(relation)==NIL && relation->rd_rel->relam==BTREE_AM_OID;
    result = result && relation->rd_indcollation[0] == exprCollation(expected);
    while (IsA(expected,CollateExpr)) expected=(Node *)((CollateExpr *)expected)->arg;
    expected=eval_const_expressions(NULL,expected);
    if (result && expressions==NIL)
        result=IsA(expected,Var) && ((Var *)expected)->varattno==column;
    else if (result)
        result=list_length(expressions)==1 && equal(expected,linitial(expressions));
    index_close(relation,AccessShareLock);
    PG_RETURN_BOOL(result);
}

PG_FUNCTION_INFO_V1(pg_splitjson_management_target);
Datum
pg_splitjson_management_target(PG_FUNCTION_ARGS)
{
    PG_RETURN_BOOL(entry && entry->admin && entry->view!=PG_GETARG_OID(0));
}

/* The executor already holds RowExclusiveLock before this statement trigger.
 * Inspect current fence metadata even in an old REPEATABLE READ transaction.
 * A fence takes AccessExclusiveLock first, so an earlier writer finishes before
 * the fence and a later writer cannot slip past an obsolete catalog snapshot.
 * Native replica apply skips this origin-only trigger. Direct private writes
 * without an API context remain a trusted installer operation (online replay).
 */
PG_FUNCTION_INFO_V1(pg_splitjson_storage_write_guard);
Datum
pg_splitjson_storage_write_guard(PG_FUNCTION_ARGS)
{
    TriggerData *trigger;
    Oid types[1] = {OIDOID};
    Datum values[1];
    SPIPlanPtr plan;
    bool isnull;
    bool blocked = false;

    if (!CALLED_AS_TRIGGER(fcinfo))
        elog(ERROR,"storage write guard must be called as a trigger");
    trigger = (TriggerData *)fcinfo->context;
    if (entry==NULL && superuser() && !TRIGGER_FIRED_BY_TRUNCATE(trigger->tg_event))
        PG_RETURN_POINTER(NULL);
    values[0] = ObjectIdGetDatum(RelationGetRelid(trigger->tg_relation));
    if (SPI_connect()!=SPI_OK_CONNECT)
        elog(ERROR,"SPI_connect failed");
    plan=SPI_prepare("SELECT follower_mode OR write_fenced, "
                     "EXISTS(SELECT 1 FROM splitjson._jobs j WHERE j.source_name=m.view_name AND j.state NOT IN ('completed','aborted')) OR "
                     "EXISTS(SELECT 1 FROM splitjson._replicas r WHERE r.view_name=m.view_name AND r.state NOT IN ('detached','promoted')) "
                     "FROM splitjson._tables m "
                     "WHERE to_regclass(storage_name)=$1 OR to_regclass(storage_name) IN "
                     "(SELECT pg_partition_ancestors($1::regclass))",1,types);
    if (plan==NULL || SPI_execute_snapshot(plan,values,NULL,GetLatestSnapshot(),
                                          InvalidSnapshot,true,false,1)!=SPI_OK_SELECT || SPI_processed!=1)
        elog(ERROR,"storage write guard mapping is missing");
    blocked=DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0],SPI_tuptable->tupdesc,1,&isnull));
    if (TRIGGER_FIRED_BY_TRUNCATE(trigger->tg_event) &&
        DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0],SPI_tuptable->tupdesc,2,&isnull)))
        ereport(ERROR,(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),errmsg("active migration/replication prevents source TRUNCATE")));
    SPI_finish();
    if (isnull || blocked)
        ereport(ERROR,(errcode(ERRCODE_READ_ONLY_SQL_TRANSACTION),errmsg("managed storage is fenced or a read-only follower")));
    PG_RETURN_POINTER(NULL);
}

PG_FUNCTION_INFO_V1(pg_splitjson_query_for);
Datum
pg_splitjson_query_for(PG_FUNCTION_ARGS)
{
    Oid old_view;
    Datum result=(Datum)0;
    LOCAL_FCINFO(inner,4);
    int i;
    if (entry==NULL || !entry->admin)
        ereport(ERROR,(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),errmsg("target execution requires a trusted management entry")));
    old_view=entry->view;
    InitFunctionCallInfoData(*inner,fcinfo->flinfo,4,fcinfo->fncollation,fcinfo->context,fcinfo->resultinfo);
    for (i=0;i<4;i++) inner->args[i]=fcinfo->args[i+1];
    PG_TRY();
    {
        entry->view=PG_GETARG_OID(0);
        result=pg_splitjson_query(inner);
        fcinfo->isnull=inner->isnull;
        entry->view=old_view;
    }
    PG_CATCH();
    {
        entry->view=old_view;
        PG_RE_THROW();
    }
    PG_END_TRY();
    return result;
}

static bool
nonconstant_default(Node *node, void *unused)
{
    if (node==NULL) return false;
    if (IsA(node,Const))
    {
        HeapTuple tuple=SearchSysCache1(TYPEOID,ObjectIdGetDatum(((Const *)node)->consttype));
        bool safe=HeapTupleIsValid(tuple) && ((Form_pg_type)GETSTRUCT(tuple))->typnamespace==PG_CATALOG_NAMESPACE;
        if (HeapTupleIsValid(tuple)) ReleaseSysCache(tuple);
        return !safe;
    }
    if (IsA(node,FuncExpr))
    {
        FuncExpr *f=(FuncExpr *)node;
        if (get_func_namespace(f->funcid)!=PG_CATALOG_NAMESPACE || func_volatile(f->funcid)!='i' || f->funcretset)
            return true;
    }
    else if (IsA(node,OpExpr))
    {
        Oid function=get_opcode(((OpExpr *)node)->opno);
        if (get_func_namespace(function)!=PG_CATALOG_NAMESPACE || func_volatile(function)!='i') return true;
    }
    else if (!(IsA(node,RelabelType) || IsA(node,ArrayExpr) || IsA(node,CollateExpr) || IsA(node,List))) return true;
    return expression_tree_walker(node,nonconstant_default,unused);
}

PG_FUNCTION_INFO_V1(pg_splitjson_constant_default);
Datum
pg_splitjson_constant_default(PG_FUNCTION_ARGS)
{
    Oid type=OIDOID;
    Datum value=PG_GETARG_DATUM(0);
    bool isnull;
    bool safe=false;
    if (!entry) ereport(ERROR,(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),errmsg("default inspection requires a trusted entry")));
    if (SPI_connect()!=SPI_OK_CONNECT) elog(ERROR,"SPI_connect failed");
    if (SPI_execute_with_args("SELECT adbin::text FROM pg_catalog.pg_attrdef WHERE oid=$1",1,&type,&value,NULL,true,1)!=SPI_OK_SELECT)
        elog(ERROR,"default inspection failed");
    if (SPI_processed==1)
    {
        char *serialized=TextDatumGetCString(SPI_getbinval(SPI_tuptable->vals[0],SPI_tuptable->tupdesc,1,&isnull));
        safe=!nonconstant_default(stringToNode(serialized),NULL);
    }
    SPI_finish();
    PG_RETURN_BOOL(safe);
}
