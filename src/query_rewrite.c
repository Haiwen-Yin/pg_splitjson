/* Copyright 2026 PG SplitJSON contributors
 * SPDX-License-Identifier: Apache-2.0
 */

/* PG18 planner integration. Only canonical, unfiltered managed view projections
 * are rewritten. Original view/storage permission records and barriers survive. */
#include "postgres.h"
#include "miscadmin.h"
#include "catalog/namespace.h"
#include "catalog/pg_extension.h"
#include "executor/spi.h"
#include "catalog/pg_collation_d.h"
#include "catalog/pg_type_d.h"
#include "catalog/pg_type.h"
#include "commands/extension.h"
#include "utils/syscache.h"
#include "parser/parsetree.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/planner.h"
#include "optimizer/optimizer.h"
#include "parser/parse_func.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/plancache.h"

PGDLLEXPORT void _PG_init(void);
PGDLLEXPORT void _PG_fini(void);

static planner_hook_type previous_planner = NULL;
static bool rewrite_enabled = true;
static bool checking_registration = false;

/* A native #> segment may address either a key or an index. -> fixes the kind. */
typedef struct Step
{
    int kind;                     /* 0 native text path, 1 object key, 2 array index */
    char *key;
    int index;
} Step;

typedef struct Extraction
{
    Var *base;
    int depth;
    Step steps[64];
    bool as_text;
} Extraction;

typedef struct Managed
{
    Query *query;
    RangeTblEntry *rte;
    Index outer_varno;
    AttrNumber doc_attr;
    Jsonb *paths;
    List *hot;
    int *projections;
} Managed;

typedef struct RewriteContext
{
    Query *query;
    List *managed;
    Oid restore_oid;
} RewriteContext;

typedef struct WholeRowContext
{
    Index varno;
    int level;
} WholeRowContext;

static Query *rewrite_query(Query *query, Oid restore_oid);

/* Query only the installer-owned registry, with a recursion guard and complete
 * restoration of the caller's security context on both success and error.
 * Registration is checked at planning time; no backend-lifetime slot cache. */
static bool
registered_projection(Oid view, Oid storage, Jsonb *paths)
{
    Oid extension = get_extension_oid("pg_splitjson", true);
    HeapTuple tuple;
    Oid owner;
    Oid saved_user;
    int saved_context;
    bool result = false;
    bool saved_check = checking_registration;
    Oid types[3] = {TEXTOID, TEXTOID, JSONBOID};
    Datum values[3];

    if (!OidIsValid(extension))
        return false;
    tuple = SearchSysCache1(EXTENSIONOID, ObjectIdGetDatum(extension));
    if (!HeapTupleIsValid(tuple))
        return false;
    owner = ((Form_pg_extension) GETSTRUCT(tuple))->extowner;
    ReleaseSysCache(tuple);
    values[0] = CStringGetTextDatum(quote_qualified_identifier(
                    get_namespace_name(get_rel_namespace(view)), get_rel_name(view)));
    values[1] = CStringGetTextDatum(quote_qualified_identifier(
                    get_namespace_name(get_rel_namespace(storage)), get_rel_name(storage)));
    values[2] = JsonbPGetDatum(paths);
    GetUserIdAndSecContext(&saved_user, &saved_context);
    PG_TRY();
    {
        bool isnull;
        Datum exists;

        checking_registration = true;
        SetUserIdAndSecContext(owner, saved_context | SECURITY_LOCAL_USERID_CHANGE);
        if (SPI_connect() != SPI_OK_CONNECT)
            elog(ERROR, "SPI_connect failed");
        if (SPI_execute_with_args("SELECT EXISTS (SELECT 1 FROM splitjson._tables "
                                  "WHERE view_name=$1 AND storage_name=$2 AND paths=$3)",
                                  3, types, values, NULL, true, 1) != SPI_OK_SELECT)
            elog(ERROR, "managed view registration check failed");
        exists = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
        result = !isnull && DatumGetBool(exists);
        SPI_finish();
        SetUserIdAndSecContext(saved_user, saved_context);
        checking_registration = saved_check;
    }
    PG_CATCH();
    {
        SetUserIdAndSecContext(saved_user, saved_context);
        checking_registration = saved_check;
        PG_RE_THROW();
    }
    PG_END_TRY();
    return result;
}

/* Appending internal outputs changes the subquery tuple descriptor. Keep whole
 * view-row references native, including correlated references in child queries. */
static bool
whole_row_walker(Node *node, WholeRowContext *context)
{
    if (node == NULL)
        return false;
    if (IsA(node, Var))
    {
        Var *var = (Var *) node;

        return var->varattno == 0 && var->varno == context->varno &&
               var->varlevelsup == context->level;
    }
    if (IsA(node, Query))
    {
        bool found;

        context->level++;
        found = query_tree_walker((Query *) node, whole_row_walker, context, 0);
        context->level--;
        return found;
    }
    return expression_tree_walker(node, whole_row_walker, context);
}

static bool
append_step(Extraction *out, int kind, char *key, int index)
{
    Step *step;

    if (out->depth >= 64 || out->as_text)
        return false;
    step = &out->steps[out->depth++];
    step->kind = kind;
    step->key = key;
    step->index = index;
    return true;
}

static bool
extract_path(Node *node, Extraction *out)
{
    Oid function;
    List *args;
    Node *argument;
    Const *constant;
    bool text_result = false;

    check_stack_depth();

    if (IsA(node, Var))
    {
        Var *var = (Var *) node;

        if (var->varlevelsup != 0 || var->vartype != JSONBOID || var->varattno <= 0)
            return false;
        out->base = var;
        return true;
    }
    if (IsA(node, OpExpr))
    {
        OpExpr *op = (OpExpr *) node;

        function = get_opcode(op->opno);
        args = op->args;
    }
    else if (IsA(node, FuncExpr))
    {
        FuncExpr *func = (FuncExpr *) node;

        function = func->funcid;
        args = func->args;
    }
    else
        return false;
    if (list_length(args) != 2 || !extract_path(linitial(args), out) || out->as_text)
        return false;
    argument = lsecond(args);
    if (function == F_JSONB_OBJECT_FIELD || function == F_JSONB_OBJECT_FIELD_TEXT)
    {
        if (!IsA(argument, Const))
            return false;
        constant = (Const *) argument;
        if (constant->constisnull || constant->consttype != TEXTOID)
            return false;
        if (!append_step(out, 1, TextDatumGetCString(constant->constvalue), 0))
            return false;
        text_result = function == F_JSONB_OBJECT_FIELD_TEXT;
    }
    else if (function == F_JSONB_ARRAY_ELEMENT || function == F_JSONB_ARRAY_ELEMENT_TEXT)
    {
        int index;

        if (!IsA(argument, Const))
            return false;
        constant = (Const *) argument;
        if (constant->constisnull || constant->consttype != INT4OID)
            return false;
        index = DatumGetInt32(constant->constvalue);
        if (index < 0 || !append_step(out, 2, NULL, index))
            return false;
        text_result = function == F_JSONB_ARRAY_ELEMENT_TEXT;
    }
    else if (function == F_JSONB_EXTRACT_PATH || function == F_JSONB_EXTRACT_PATH_TEXT)
    {
        if (IsA(argument, Const))
        {
            Datum *elements;
            bool *nulls;
            int count;
            int i;

            constant = (Const *) argument;
            if (constant->constisnull || constant->consttype != TEXTARRAYOID)
                return false;
            deconstruct_array(DatumGetArrayTypeP(constant->constvalue), TEXTOID, -1,
                              false, TYPALIGN_INT, &elements, &nulls, &count);
            for (i = 0; i < count; i++)
                if (nulls[i] || !append_step(out, 0, TextDatumGetCString(elements[i]), 0))
                    return false;
        }
        else if (IsA(argument, ArrayExpr))
        {
            ArrayExpr *array = (ArrayExpr *) argument;
            ListCell *lc;

            if (array->multidims || array->element_typeid != TEXTOID)
                return false;
            foreach(lc, array->elements)
            {
                constant = lfirst(lc);
                if (!IsA(constant, Const) || constant->constisnull || constant->consttype != TEXTOID ||
                    !append_step(out, 0, TextDatumGetCString(constant->constvalue), 0))
                    return false;
            }
        }
        else
            return false;
        text_result = function == F_JSONB_EXTRACT_PATH_TEXT;
    }
    else
        return false;
    out->as_text = text_result;
    return true;
}

static int
matching_slot(Managed *managed, Extraction *extraction)
{
    uint32 count = JB_ROOT_COUNT(managed->paths);
    uint32 i;
    int result = -1;

    /* ->0 also extracts scalars as singleton arrays; declarations only extract
     * real array containers. A final ->0 must retain its native expression. */
    if (extraction->depth > 0 && extraction->steps[extraction->depth - 1].kind == 2 &&
        extraction->steps[extraction->depth - 1].index == 0)
        return -1;

    for (i = 0; i < count; i++)
    {
        JsonbValue *path = getIthJsonbValueFromContainer(&managed->paths->root, i);
        int j;

        if (path->type != jbvBinary || JsonContainerSize(path->val.binary.data) != extraction->depth)
            continue;
        for (j = 0; j < extraction->depth; j++)
        {
            JsonbValue *segment = getIthJsonbValueFromContainer(path->val.binary.data, j);
            Step *step = &extraction->steps[j];

            /* Native text paths choose object keys or array indexes at runtime.
             * A single typed slot cannot represent both shapes. */
            if (step->kind == 0)
            {
                char *end;

                (void) strtol(step->key, &end, 10);
                if (end != step->key && *end == '\0')
                    break;
            }

            if (segment->type == jbvString)
            {
                if (step->kind == 2 || step->key == NULL ||
                    strlen(step->key) != segment->val.string.len ||
                    memcmp(step->key, segment->val.string.val, segment->val.string.len) != 0)
                    break;
            }
            else if (segment->type == jbvNumeric)
            {
                int declared = DatumGetInt32(DirectFunctionCall1(numeric_int4,
                                                     NumericGetDatum(segment->val.numeric)));

                if (step->kind == 1)
                    break;
                if (step->kind == 2)
                {
                    if (step->index != declared)
                        break;
                }
                else
                {
                    char buf[32];

                    pg_ltoa(declared, buf);
                    if (strcmp(buf, step->key) != 0)
                        break; /* Noncanonical aliases safely retain native expressions. */
                }
            }
            else
                break;
        }
        if (j == extraction->depth)
        {
            if (result != -1)
                return -1; /* Mixed shapes: retain the native expression. */
            result = i;
        }
    }
    return result;
}

static Managed *
inspect_view(RangeTblEntry *rte, Index varno, Oid restore_oid)
{
    Query *query = rte->subquery;
    TargetEntry *doc;
    FuncExpr *restore;
    Var *cold;
    ArrayExpr *hot;
    Const *paths;
    RangeTblRef *reference;
    RangeTblEntry *storage;
    ListCell *lc;
    Managed *managed;

    if (!OidIsValid(rte->relid) || rte->perminfoindex == 0 || !rte->security_barrier || query->commandType != CMD_SELECT ||
        query->hasAggs || query->hasWindowFuncs || query->hasTargetSRFs ||
        query->setOperations || query->groupClause || query->distinctClause ||
        query->limitCount || query->limitOffset || query->havingQual || query->cteList ||
        query->rowMarks || query->sortClause || !query->jointree || query->jointree->quals ||
        list_length(query->jointree->fromlist) != 1 || list_length(query->targetList) < 2)
        return NULL;
    reference = linitial(query->jointree->fromlist);
    if (!IsA(reference, RangeTblRef))
        return NULL;
    storage = rt_fetch(reference->rtindex, query->rtable);
    if (storage->rtekind != RTE_RELATION || storage->securityQuals ||
        get_rel_namespace(storage->relid) != get_namespace_oid("splitjson_storage", true))
        return NULL;
    doc = list_nth_node(TargetEntry, query->targetList, 1);
    if (doc->resjunk || !IsA(doc->expr, FuncExpr))
        return NULL;
    restore = (FuncExpr *) doc->expr;
    if (restore->funcid != restore_oid || list_length(restore->args) != 3 ||
        !IsA(linitial(restore->args), Var) || !IsA(lsecond(restore->args), ArrayExpr) || !IsA(lthird(restore->args), Const))
        return NULL;
    cold = linitial_node(Var, restore->args);
    if (cold->varno != reference->rtindex || cold->varattno != 2 || cold->varlevelsup != 0)
        return NULL;
    hot = lsecond_node(ArrayExpr, restore->args);
    paths = lthird_node(Const, restore->args);
    if (paths->constisnull || paths->consttype != JSONBOID || hot->multidims || hot->element_typeid != JSONBOID)
        return NULL;
    foreach(lc, hot->elements)
    {
        Var *value = lfirst(lc);

        if (!IsA(value, Var) || value->varno != reference->rtindex ||
            value->varlevelsup != 0 || value->vartype != JSONBOID || value->varattno < 3)
            return NULL;
    }
    if (!JB_ROOT_IS_ARRAY(DatumGetJsonbP(paths->constvalue)) ||
        JB_ROOT_COUNT(DatumGetJsonbP(paths->constvalue)) != list_length(hot->elements))
        return NULL;
    if (!registered_projection(rte->relid,storage->relid,DatumGetJsonbP(paths->constvalue)))
        return NULL;
    managed = palloc0(sizeof(Managed));
    managed->query = query;
    managed->rte = rte;
    managed->outer_varno = varno;
    managed->doc_attr = doc->resno;
    managed->paths = DatumGetJsonbP(paths->constvalue);
    managed->hot = hot->elements;
    managed->projections = palloc0(sizeof(int) * list_length(hot->elements));
    return managed;
}

static Node *
hot_value(Managed *managed, int slot, bool as_text, bool internal, Oid collation)
{
    Node *value;

    if (internal)
        value = copyObject(list_nth(managed->hot, slot));
    else
    {
        int resno = managed->projections[slot];

        if (resno == 0)
        {
            TargetEntry *target;

            resno = list_length(managed->query->targetList) + 1;
            target = makeTargetEntry((Expr *) copyObject(list_nth(managed->hot, slot)),
                                     resno, pstrdup("__splitjson_hot"), false);
            managed->query->targetList = lappend(managed->query->targetList, target);
            managed->rte->eref->colnames = lappend(managed->rte->eref->colnames, makeString(psprintf("__splitjson_hot_%d",slot+1)));
            managed->projections[slot] = resno;
        }
        value = (Node *) makeVar(managed->outer_varno, resno, JSONBOID, -1, InvalidOid, 0);
    }
    if (as_text)
    {
        OpExpr *op = makeNode(OpExpr);
        Oid operator = OpernameGetOprid(list_make2(makeString("pg_catalog"), makeString("#>>")),
                                       JSONBOID, TEXTARRAYOID);
        Const *empty = makeConst(TEXTARRAYOID, -1, DEFAULT_COLLATION_OID, -1,
                                PointerGetDatum(construct_empty_array(TEXTOID)), false, false);

        op->opno = operator;
        op->opfuncid = get_opcode(operator);
        op->opresulttype = TEXTOID;
        op->opcollid = collation;
        op->inputcollid = DEFAULT_COLLATION_OID;
        op->args = list_make2(value, empty);
        op->location = -1;
        value = (Node *) op;
    }
    return value;
}

static Managed *
resolve_extraction(RewriteContext *context, Extraction *out, int *slot)
{
    ListCell *lc;

    foreach(lc, context->managed)
    {
        Managed *managed = lfirst(lc);

        if (out->base->varno == managed->outer_varno && out->base->varattno == managed->doc_attr)
        {
            *slot = matching_slot(managed, out);
            if (*slot >= 0)
                return managed;
        }
    }
    return NULL;
}

static Node *
rewrite_expression(Node *node, RewriteContext *context)
{
    Extraction out = {0};
    Managed *managed;
    int slot;

    if (node == NULL)
        return NULL;
    if (IsA(node, Query))
        return (Node *) rewrite_query((Query *) node, context->restore_oid);
    if (extract_path(node, &out) && out.depth > 0 &&
        (managed = resolve_extraction(context, &out, &slot)) != NULL)
    {
        Node *replacement = hot_value(managed, slot, out.as_text, false, exprCollation(node));
        Var *var = out.as_text ? linitial_node(Var, ((OpExpr *) replacement)->args) : (Var *) replacement;

        var->varnullingrels = bms_copy(out.base->varnullingrels);
        return replacement;
    }
    return expression_tree_mutator(node, rewrite_expression, context);
}

/* The canonical view has no row restrictions or RLS. Push only builtin equality
 * on a publicly readable logical hot value against a Const/Param, preserving all
 * original permission records. No user-defined function crosses the barrier. */
static Node *
rewrite_qual(Node *node, RewriteContext *context)
{
    if (node == NULL)
        return NULL;
    if (IsA(node, BoolExpr) && ((BoolExpr *) node)->boolop == AND_EXPR)
    {
        BoolExpr *result = copyObject((BoolExpr *) node);
        List *args = NIL;
        ListCell *lc;

        foreach(lc, result->args)
            args = lappend(args, rewrite_qual(lfirst(lc), context));
        result->args = args;
        return (Node *) result;
    }
    if (IsA(node, OpExpr))
    {
        OpExpr *op = (OpExpr *) node;
        Oid type = InvalidOid;
        Oid equality;
        int side;

        if (list_length(op->args) != 2)
            return rewrite_expression(node, context);
        if (exprType(linitial(op->args)) == JSONBOID && exprType(lsecond(op->args)) == JSONBOID)
            type = JSONBOID;
        else if (exprType(linitial(op->args)) == TEXTOID && exprType(lsecond(op->args)) == TEXTOID)
            type = TEXTOID;
        if (!OidIsValid(type))
            return rewrite_expression(node, context);
        equality = OpernameGetOprid(list_make2(makeString("pg_catalog"), makeString("=")),type,type);
        if (op->opno != equality)
            return rewrite_expression(node, context);
        for (side = 0; side < 2; side++)
        {
            Node *extract = list_nth(op->args, side);
            Node *other = list_nth(op->args, 1-side);
            Extraction out = {0};
            Managed *managed;
            int slot;

            if ((!IsA(other, Const) && (!IsA(other, Param) || ((Param *) other)->paramkind != PARAM_EXTERN)) ||
                !extract_path(extract, &out) || out.depth == 0 ||
                (managed = resolve_extraction(context, &out, &slot)) == NULL)
                continue;
            {
                OpExpr *inner = copyObject(op);
                Node *hot = hot_value(managed, slot, out.as_text, true, exprCollation(extract));

                inner->args = side == 0 ? list_make2(hot, copyObject(other)) : list_make2(copyObject(other), hot);
                managed->query->jointree->quals = (Node *) makeBoolExpr(AND_EXPR,
                    list_make2(managed->query->jointree->quals ? managed->query->jointree->quals :
                               (Node *) makeBoolConst(true, false), inner), -1);
                return rewrite_expression(node, context);
            }
        }
    }
    return rewrite_expression(node, context);
}

static Query *
rewrite_query(Query *query, Oid restore_oid)
{
    RewriteContext context = {0};
    ListCell *lc;
    Index varno = 0;

    check_stack_depth();

    if (query->commandType != CMD_SELECT)
        return query;
    context.query = query;
    context.restore_oid = restore_oid;
    foreach(lc, query->rtable)
    {
        RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);

        varno++;
        if (rte->rtekind == RTE_SUBQUERY)
        {
            Managed *managed = inspect_view(rte, varno, restore_oid);
            WholeRowContext whole = {varno, 0};

            if (managed != NULL && !query_tree_walker(query, whole_row_walker, &whole, 0))
                context.managed = lappend(context.managed, managed);
            else
                rte->subquery = rewrite_query(rte->subquery, restore_oid);
        }
    }
    if (context.managed != NIL && query->jointree)
        query->jointree->quals = rewrite_qual(query->jointree->quals, &context);
    return query_tree_mutator(query, rewrite_expression, &context, QTW_IGNORE_RT_SUBQUERIES);
}

static PlannedStmt *
splitjson_planner(Query *parse, const char *query_string, int cursor_options, ParamListInfo parameters)
{
    if (!checking_registration && rewrite_enabled && OidIsValid(get_extension_oid("pg_splitjson", true)) &&
        OidIsValid(get_namespace_oid("splitjson", true)))
    {
        Oid types[3];
        Oid restore;
        Oid cold;

        /* Qualified type lookup without search_path dependence. */
        cold = GetSysCacheOid2(TYPENAMENSP, Anum_pg_type_oid,
                              CStringGetDatum("cold"), ObjectIdGetDatum(get_namespace_oid("splitjson", true)));
        if (OidIsValid(cold))
        {
            types[0] = cold;
            types[1] = JSONBARRAYOID;
            types[2] = JSONBOID;
            restore = LookupFuncName(list_make2(makeString("splitjson"), makeString("restore")), 3, types, true);
            if (OidIsValid(restore))
                parse = rewrite_query(copyObject(parse), restore);
        }
    }
    if (previous_planner)
        return previous_planner(parse, query_string, cursor_options, parameters);
    return standard_planner(parse, query_string, cursor_options, parameters);
}

static void
assign_rewrite(bool value, void *extra)
{
    ResetPlanCache();
}

void
_PG_init(void)
{
    DefineCustomBoolVariable("splitjson.enable_query_rewrite", "Rewrite managed JSON hot paths during planning.",
                             NULL, &rewrite_enabled, true, PGC_USERSET, 0, NULL, assign_rewrite, NULL);
    previous_planner = planner_hook;
    planner_hook = splitjson_planner;
}

void
_PG_fini(void)
{
    if (planner_hook == splitjson_planner)
        planner_hook = previous_planner;
}
