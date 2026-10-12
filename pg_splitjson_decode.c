/* Copyright 2026 PG SplitJSON contributors
 * SPDX-License-Identifier: Apache-2.0
 */

/* Optional logical decoder. Protocol v1 carries explicit column state: a SQL
 * NULL is JSON null; an unchanged external TOAST value is {"unchanged":true};
 * every full value is {"text":...,"type":...}. Text never becomes SQL. */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "access/htup_details.h"
#include "catalog/partition.h"
#include "catalog/pg_type_d.h"
#include "commands/defrem.h"
#include "executor/spi.h"
#include "replication/logical.h"
#include "replication/output_plugin.h"
#include "utils/builtins.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"

PG_MODULE_MAGIC;

typedef struct DecodeState
{
    Oid source;
} DecodeState;

static void decode_startup(LogicalDecodingContext *ctx, OutputPluginOptions *options, bool is_init);
static void decode_begin(LogicalDecodingContext *ctx, ReorderBufferTXN *txn);
static void decode_change(LogicalDecodingContext *ctx, ReorderBufferTXN *txn, Relation relation, ReorderBufferChange *change);
static void decode_commit(LogicalDecodingContext *ctx, ReorderBufferTXN *txn, XLogRecPtr lsn);
static void decode_truncate(LogicalDecodingContext *ctx, ReorderBufferTXN *txn, int count, Relation relations[], ReorderBufferChange *change);

void
_PG_output_plugin_init(OutputPluginCallbacks *cb)
{
    cb->startup_cb = decode_startup;
    cb->begin_cb = decode_begin;
    cb->change_cb = decode_change;
    cb->commit_cb = decode_commit;
    cb->truncate_cb = decode_truncate;
}

static void
decode_startup(LogicalDecodingContext *ctx, OutputPluginOptions *options, bool is_init)
{
    DecodeState *state = palloc0(sizeof(DecodeState));
    ListCell *lc;
    char *source = NULL;

    ctx->output_plugin_private = state;
    options->output_type = OUTPUT_PLUGIN_TEXTUAL_OUTPUT;
    options->receive_rewrites = false;
    /* Decoding is a trusted full-data operation, never a business RLS read. */
    if (!superuser())
        ereport(ERROR, (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                        errmsg("managed logical decoding requires a trusted superuser")));
    foreach(lc, ctx->output_plugin_options)
    {
        DefElem *option = lfirst(lc);

        if (strcmp(option->defname, "source") != 0 || source != NULL)
            ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("expected one managed source option")));
        source = defGetString(option);
    }
    if (source == NULL && is_init)
        return;
    if (source == NULL)
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("managed source option is required")));
    if (SPI_connect() != SPI_OK_CONNECT)
        elog(ERROR, "SPI_connect failed");
    {
        Oid types[1] = {TEXTOID};
        Datum values[1] = {CStringGetTextDatum(source)};
        bool isnull;

        if (SPI_execute_with_args("SELECT to_regclass(storage_name)::oid FROM splitjson._tables "
                                  "WHERE to_regclass(view_name)=to_regclass($1)", 1, types, values, NULL, true, 1) != SPI_OK_SELECT ||
            SPI_processed != 1)
            ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("logical source must be a registered managed relation")));
        state->source = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
        if (isnull || !OidIsValid(state->source))
            elog(ERROR, "managed source storage is missing");
    }
    SPI_finish();
}

static bool
is_source(DecodeState *state, Relation relation)
{
    Oid oid = RelationGetRelid(relation);

    return oid == state->source || (relation->rd_rel->relispartition &&
                                   list_member_oid(get_partition_ancestors(oid), state->source));
}

static void
decode_begin(LogicalDecodingContext *ctx, ReorderBufferTXN *txn)
{
    OutputPluginPrepareWrite(ctx, true);
    appendStringInfo(ctx->out, "{\"v\":1,\"event\":\"begin\",\"xid\":%u}", txn->xid);
    OutputPluginWrite(ctx, true);
}

static void
tuple_json(StringInfo out, HeapTuple tuple, TupleDesc desc)
{
    int i;
    bool first = true;

    if (tuple == NULL)
    {
        appendStringInfoString(out, "null");
        return;
    }
    appendStringInfoChar(out, '{');
    for (i = 0; i < desc->natts; i++)
    {
        Form_pg_attribute attr = TupleDescAttr(desc, i);
        bool isnull;
        Datum value;
        Oid output;
        bool varlena;

        if (attr->attisdropped)
            continue;
        if (!first)
            appendStringInfoChar(out, ',');
        first = false;
        escape_json(out, NameStr(attr->attname));
        appendStringInfoChar(out, ':');
        value = heap_getattr(tuple, i + 1, desc, &isnull);
        if (isnull)
            appendStringInfoString(out, "null");
        else if (attr->attlen == -1 && VARATT_IS_EXTERNAL_ONDISK(DatumGetPointer(value)))
            appendStringInfoString(out, "{\"unchanged\":true}");
        else
        {
            char *text;

            getTypeOutputInfo(attr->atttypid, &output, &varlena);
            text = OidOutputFunctionCall(output, value);
            appendStringInfoString(out, "{\"text\":");
            escape_json(out, text);
            appendStringInfoString(out, ",\"type\":");
            escape_json(out, format_type_be(attr->atttypid));
            appendStringInfoChar(out, '}');
        }
    }
    appendStringInfoChar(out, '}');
}

static void
decode_change(LogicalDecodingContext *ctx, ReorderBufferTXN *txn, Relation relation, ReorderBufferChange *change)
{
    DecodeState *state = ctx->output_plugin_private;
    const char *operation;

    if (!is_source(state, relation))
        return;
    switch (change->action)
    {
        case REORDER_BUFFER_CHANGE_INSERT: operation = "insert"; break;
        case REORDER_BUFFER_CHANGE_UPDATE: operation = "update"; break;
        case REORDER_BUFFER_CHANGE_DELETE: operation = "delete"; break;
        default: elog(ERROR, "unsupported managed WAL change"); operation = NULL;
    }
    OutputPluginPrepareWrite(ctx, true);
    appendStringInfo(ctx->out, "{\"v\":1,\"event\":\"%s\",\"xid\":%u,\"source\":%u,\"relation\":%u,\"old\":",
                     operation, txn->xid, state->source, RelationGetRelid(relation));
    tuple_json(ctx->out, change->data.tp.oldtuple, RelationGetDescr(relation));
    appendStringInfoString(ctx->out, ",\"new\":");
    tuple_json(ctx->out, change->data.tp.newtuple, RelationGetDescr(relation));
    appendStringInfoChar(ctx->out, '}');
    OutputPluginWrite(ctx, true);
}

static void
decode_commit(LogicalDecodingContext *ctx, ReorderBufferTXN *txn, XLogRecPtr lsn)
{
    OutputPluginPrepareWrite(ctx, true);
    appendStringInfo(ctx->out, "{\"v\":1,\"event\":\"commit\",\"xid\":%u,\"lsn\":\"%X/%X\",\"end_lsn\":\"%X/%X\"}",
                     txn->xid, LSN_FORMAT_ARGS(lsn), LSN_FORMAT_ARGS(txn->end_lsn));
    OutputPluginWrite(ctx, true);
}

static void
decode_truncate(LogicalDecodingContext *ctx, ReorderBufferTXN *txn, int count, Relation relations[], ReorderBufferChange *change)
{
    DecodeState *state = ctx->output_plugin_private;
    int i;

    for (i = 0; i < count; i++)
        if (is_source(state, relations[i]))
            ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                            errmsg("managed online capture does not support source TRUNCATE; rebootstrap required")));
}
