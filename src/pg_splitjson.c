/* Copyright 2026 PG SplitJSON contributors
 * SPDX-License-Identifier: Apache-2.0
 */

/* PostgreSQL 18 only. Cold payloads are immutable, TOAST-able values. */
#include "postgres.h"
#include "fmgr.h"
#include "catalog/pg_type_d.h"
#include "commands/event_trigger.h"
#include "executor/spi.h"
#include "libpq/pqformat.h"
#include "miscadmin.h"
#include "parser/parse_type.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "utils/lsyscache.h"
#include "utils/varlena.h"
#include <errno.h>
#include <limits.h>

#if PG_VERSION_NUM < 180000 || PG_VERSION_NUM >= 190000
#error "pg_splitjson requires PostgreSQL 18"
#endif

PG_MODULE_MAGIC;

#define COLD_MAGIC 0x50474a53U
#define COLD_VERSION 2U
#define MAX_PATHS 64
#define MAX_DEPTH 64

typedef struct Cold
{
    int32 vl_len_;
    uint32 magic;
    uint32 version;
    uint32 paths_len;
    uint32 template_len;
    char data[FLEXIBLE_ARRAY_MEMBER];
} Cold;

#define COLD_HEADER MAXALIGN(offsetof(Cold, data))

typedef struct Path
{
    int depth;
    JsonbValue *keys;
    ArrayType *sqlpath;
} Path;

typedef struct Paths
{
    int count;
    Path *items;
} Paths;

PG_FUNCTION_INFO_V1(pg_splitjson_cold_in);
PG_FUNCTION_INFO_V1(pg_splitjson_cold_out);
PG_FUNCTION_INFO_V1(pg_splitjson_validate_paths);
PG_FUNCTION_INFO_V1(pg_splitjson_pack);
PG_FUNCTION_INFO_V1(pg_splitjson_slots);
PG_FUNCTION_INFO_V1(pg_splitjson_restore);
PG_FUNCTION_INFO_V1(pg_splitjson_template);
PG_FUNCTION_INFO_V1(pg_splitjson_paths);
PG_FUNCTION_INFO_V1(pg_splitjson_assert_object_path);
PG_FUNCTION_INFO_V1(pg_splitjson_object_field);
PG_FUNCTION_INFO_V1(pg_splitjson_column_type);
PG_FUNCTION_INFO_V1(pg_splitjson_hot_route);
PG_FUNCTION_INFO_V1(pg_splitjson_path_candidates);
PG_FUNCTION_INFO_V1(pg_splitjson_ddl_start_guard);
PG_FUNCTION_INFO_V1(pg_splitjson_cold_send);
PG_FUNCTION_INFO_V1(pg_splitjson_cold_recv);

static void
invalid_path(const char *message)
{
    ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("%s", message)));
}

static Paths
parse_paths(Jsonb *json, bool allow_indexes)
{
    Paths paths;
    int i;
    int j;

    if (!JB_ROOT_IS_ARRAY(json) || JB_ROOT_IS_SCALAR(json))
        invalid_path("hot paths must be a JSON array of key/index arrays");
    paths.count = JB_ROOT_COUNT(json);
    if (paths.count > MAX_PATHS)
        invalid_path("at most 64 hot paths are supported");
    paths.items = palloc0(sizeof(Path) * Max(paths.count, 1));

    for (i = 0; i < paths.count; i++)
    {
        JsonbValue *value = getIthJsonbValueFromContainer(&json->root, i);
        Path *path = &paths.items[i];
        Datum *keys;

        CHECK_FOR_INTERRUPTS();
        if (value->type != jbvBinary ||
            !JsonContainerIsArray(value->val.binary.data) ||
            JsonContainerIsScalar(value->val.binary.data))
            invalid_path("each hot path must be a nonempty JSON array of keys/indexes");
        path->depth = JsonContainerSize(value->val.binary.data);
        if (path->depth == 0 || path->depth > MAX_DEPTH)
            invalid_path("hot path depth must be between 1 and 64");
        path->keys = palloc(sizeof(JsonbValue) * path->depth);
        keys = palloc(sizeof(Datum) * path->depth);
        for (j = 0; j < path->depth; j++)
        {
            JsonbValue *key = getIthJsonbValueFromContainer(value->val.binary.data, j);

            if (key->type == jbvString)
                keys[j] = PointerGetDatum(cstring_to_text_with_len(key->val.string.val,
                                                                 key->val.string.len));
            else if (key->type == jbvNumeric && allow_indexes)
            {
                int32 index;
                char buf[32];
                Datum number = NumericGetDatum(key->val.numeric);
                Datum zero = DirectFunctionCall1(int4_numeric, Int32GetDatum(0));
                Datum maximum = DirectFunctionCall1(int4_numeric, Int32GetDatum(PG_INT32_MAX));

                if (DatumGetInt32(DirectFunctionCall2(numeric_cmp, number, zero)) < 0 ||
                    DatumGetInt32(DirectFunctionCall2(numeric_cmp, number, maximum)) > 0)
                    invalid_path("declared array indexes must be nonnegative int32 integers");
                index = DatumGetInt32(DirectFunctionCall1(numeric_int4, number));
                if (!DatumGetBool(DirectFunctionCall2(numeric_eq, number,
                                       DirectFunctionCall1(int4_numeric, Int32GetDatum(index)))))
                    invalid_path("declared array indexes must be integers");
                pg_ltoa(index, buf);
                keys[j] = PointerGetDatum(cstring_to_text(buf));
            }
            else
                invalid_path("path segments must be object keys or nonnegative array indexes");
            path->keys[j] = *key;
        }
        path->sqlpath = construct_array(keys, path->depth, TEXTOID, -1, false, TYPALIGN_INT);

        for (j = 0; j < i; j++)
        {
            Path *other = &paths.items[j];
            int k;
            int common = Min(path->depth, other->depth);

            for (k = 0; k < common; k++)
            {
                JsonbValue *left = &path->keys[k];
                JsonbValue *right = &other->keys[k];

                if (left->type != right->type ||
                    (left->type == jbvString &&
                     (left->val.string.len != right->val.string.len ||
                      memcmp(left->val.string.val, right->val.string.val, left->val.string.len) != 0)) ||
                    (left->type == jbvNumeric &&
                     !DatumGetBool(DirectFunctionCall2(numeric_eq,
                         NumericGetDatum(left->val.numeric), NumericGetDatum(right->val.numeric)))))
                    break;
            }
            if (k == common)
                invalid_path("hot paths must not duplicate or overlap ancestor paths");
        }
    }
    return paths;
}

/* Declared strings address objects; numbers address fixed array positions. */
static JsonbValue *
lookup_object_path(Jsonb *json, const Path *path, JsonbValue *result)
{
    JsonbContainer *container = &json->root;
    int i;

    for (i = 0; i < path->depth; i++)
    {
        JsonbValue *key = &path->keys[i];
        JsonbValue *found;

        if (key->type == jbvString && JsonContainerIsObject(container))
            found = getKeyJsonValueFromContainer(container, key->val.string.val,
                                                key->val.string.len, result);
        else if (key->type == jbvNumeric && JsonContainerIsArray(container) &&
                 !JsonContainerIsScalar(container))
        {
            int32 index = DatumGetInt32(DirectFunctionCall1(numeric_int4,
                                                   NumericGetDatum(key->val.numeric)));
            found = getIthJsonbValueFromContainer(container, index);
            if (found != NULL)
                *result = *found;
        }
        else
            return NULL;
        if (found == NULL)
            return NULL;
        if (i + 1 < path->depth)
        {
            if (result->type != jbvBinary)
                return NULL;
            container = result->val.binary.data;
        }
    }
    return result;
}

static Cold *
make_cold(Jsonb *paths, Jsonb *template, uint32 version)
{
    Size plen = VARSIZE(paths);
    Size tlen = VARSIZE(template);
    Size total = COLD_HEADER + MAXALIGN(plen) + tlen;
    Cold *cold;

    if (!AllocSizeIsValid(total))
        ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED), errmsg("cold value is too large")));
    cold = palloc0(total);
    SET_VARSIZE(cold, total);
    cold->magic = COLD_MAGIC;
    cold->version = version;
    cold->paths_len = plen;
    cold->template_len = tlen;
    memcpy((char *) cold + COLD_HEADER, paths, plen);
    memcpy((char *) cold + COLD_HEADER + MAXALIGN(plen), template, tlen);
    return cold;
}

static Cold *
get_cold(Datum datum, Jsonb **paths, Jsonb **template)
{
    Cold *cold = (Cold *) PG_DETOAST_DATUM(datum);
    Size total = VARSIZE(cold);

    if (total < COLD_HEADER || cold->magic != COLD_MAGIC || (cold->version != 1 && cold->version != COLD_VERSION) ||
        cold->paths_len < VARHDRSZ + sizeof(uint32) ||
        cold->template_len < VARHDRSZ + sizeof(uint32) ||
        COLD_HEADER + MAXALIGN((Size) cold->paths_len) + cold->template_len != total)
        ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("invalid pg_splitjson cold format or version")));
    *paths = (Jsonb *) ((char *) cold + COLD_HEADER);
    *template = (Jsonb *) ((char *) cold + COLD_HEADER + MAXALIGN((Size) cold->paths_len));
    if (VARSIZE(*paths) != cold->paths_len || VARSIZE(*template) != cold->template_len)
        ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("invalid pg_splitjson cold payload lengths")));
    return cold;
}

static void
check_template(Jsonb *template, const Paths *paths)
{
    int i;

    for (i = 0; i < paths->count; i++)
    {
        JsonbValue value;
        JsonbValue *found = lookup_object_path(template, &paths->items[i], &value);

        if (found != NULL && found->type != jbvNull)
            ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                            errmsg("present hot paths in a cold template must contain null placeholders")));
    }
}

Datum
pg_splitjson_cold_in(PG_FUNCTION_ARGS)
{
    Jsonb *wire = DatumGetJsonbP(DirectFunctionCall1(jsonb_in, PG_GETARG_DATUM(0)));
    JsonbValue version;
    JsonbValue path_value;
    JsonbValue template_value;
    Jsonb *paths;
    Jsonb *template;
    Paths parsed;
    uint32 format_version;

    if (!JB_ROOT_IS_OBJECT(wire) || JB_ROOT_COUNT(wire) != 3 ||
        getKeyJsonValueFromContainer(&wire->root, "version", 7, &version) == NULL ||
        getKeyJsonValueFromContainer(&wire->root, "paths", 5, &path_value) == NULL ||
        getKeyJsonValueFromContainer(&wire->root, "template", 8, &template_value) == NULL ||
        version.type != jbvNumeric)
        ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                        errmsg("cold text must have version, paths and template fields")));
    if (DatumGetBool(DirectFunctionCall2(numeric_eq, NumericGetDatum(version.val.numeric),
                                       DirectFunctionCall1(int4_numeric, Int32GetDatum(1)))))
        format_version = 1;
    else if (DatumGetBool(DirectFunctionCall2(numeric_eq, NumericGetDatum(version.val.numeric),
                                       DirectFunctionCall1(int4_numeric, Int32GetDatum(2)))))
        format_version = 2;
    else
        ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                        errmsg("supported cold format versions are 1 and 2")));
    paths = JsonbValueToJsonb(&path_value);
    template = JsonbValueToJsonb(&template_value);
    parsed = parse_paths(paths, format_version >= 2);
    check_template(template, &parsed);
    PG_RETURN_POINTER(make_cold(paths, template, format_version));
}

Datum
pg_splitjson_cold_out(PG_FUNCTION_ARGS)
{
    Jsonb *paths;
    Jsonb *template;
    StringInfoData out;

    Cold *cold = get_cold(PG_GETARG_DATUM(0), &paths, &template);

    initStringInfo(&out);
    appendStringInfo(&out, "{\"version\":%u,\"paths\":", cold->version);
    JsonbToCString(&out, &paths->root, VARSIZE(paths));
    appendStringInfoString(&out, ",\"template\":");
    JsonbToCString(&out, &template->root, VARSIZE(template));
    appendStringInfoChar(&out, '}');
    PG_RETURN_CSTRING(out.data);
}

Datum
pg_splitjson_validate_paths(PG_FUNCTION_ARGS)
{
    parse_paths(PG_GETARG_JSONB_P(0), true);
    PG_RETURN_VOID();
}

Datum
pg_splitjson_pack(PG_FUNCTION_ARGS)
{
    Jsonb *doc = PG_GETARG_JSONB_P(0);
    Jsonb *config = PG_GETARG_JSONB_P(1);
    Paths paths = parse_paths(config, true);
    Jsonb *template = doc;
    JsonbValue nullvalue;
    Jsonb *nulljson;
    int i;

    nullvalue.type = jbvNull;
    nulljson = JsonbValueToJsonb(&nullvalue);
    for (i = 0; i < paths.count; i++)
    {
        JsonbValue value;

        CHECK_FOR_INTERRUPTS();
        if (lookup_object_path(doc, &paths.items[i], &value) != NULL)
            template = DatumGetJsonbP(DirectFunctionCall4(jsonb_set, JsonbPGetDatum(template),
                                                       PointerGetDatum(paths.items[i].sqlpath),
                                                       JsonbPGetDatum(nulljson), BoolGetDatum(false)));
    }
    PG_RETURN_POINTER(make_cold(config, template, COLD_VERSION));
}

Datum
pg_splitjson_slots(PG_FUNCTION_ARGS)
{
    Jsonb *doc = PG_GETARG_JSONB_P(0);
    Paths paths = parse_paths(PG_GETARG_JSONB_P(1), true);
    Datum *values = palloc0(sizeof(Datum) * Max(paths.count, 1));
    bool *nulls = palloc0(sizeof(bool) * Max(paths.count, 1));
    int dims[1];
    int lbs[1] = {1};
    int i;

    if (paths.count == 0)
        PG_RETURN_ARRAYTYPE_P(construct_empty_array(JSONBOID));
    for (i = 0; i < paths.count; i++)
    {
        JsonbValue value;

        CHECK_FOR_INTERRUPTS();
        if (lookup_object_path(doc, &paths.items[i], &value) == NULL)
            nulls[i] = true;
        else
            values[i] = JsonbPGetDatum(JsonbValueToJsonb(&value));
    }
    dims[0] = paths.count;
    PG_RETURN_ARRAYTYPE_P(construct_md_array(values, nulls, 1, dims, lbs,
                                             JSONBOID, -1, false, TYPALIGN_INT));
}

Datum
pg_splitjson_restore(PG_FUNCTION_ARGS)
{
    Jsonb *config;
    Jsonb *template;
    Paths paths;
    ArrayType *slots = PG_GETARG_ARRAYTYPE_P(1);
    Datum *values;
    bool *nulls;
    int count;
    int i;

    Cold *cold = get_cold(PG_GETARG_DATUM(0), &config, &template);

    if (PG_NARGS() == 3 &&
        compareJsonbContainers(&config->root, &PG_GETARG_JSONB_P(2)->root) != 0)
        ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("view and cold paths disagree")));
    paths = parse_paths(config, cold->version >= 2);
    if (ARR_NDIM(slots) > 1)
        invalid_path("hot values must be a one-dimensional jsonb array");
    deconstruct_array(slots, JSONBOID, -1, false, TYPALIGN_INT, &values, &nulls, &count);
    if (count != paths.count)
        invalid_path("hot value count does not match cold path count");
    for (i = 0; i < count; i++)
    {
        JsonbValue value;
        JsonbValue *found = lookup_object_path(template, &paths.items[i], &value);

        CHECK_FOR_INTERRUPTS();
        if ((found == NULL) != nulls[i] || (found != NULL && found->type != jbvNull))
            ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                            errmsg("cold placeholder and hot value presence disagree")));
    }
    for (i = 0; i < count; i++)
    {
        if (!nulls[i])
            template = DatumGetJsonbP(DirectFunctionCall4(jsonb_set, JsonbPGetDatum(template),
                                                       PointerGetDatum(paths.items[i].sqlpath),
                                                       values[i], BoolGetDatum(false)));
    }
    PG_RETURN_JSONB_P(template);
}

Datum
pg_splitjson_template(PG_FUNCTION_ARGS)
{
    Jsonb *paths;
    Jsonb *template;

    get_cold(PG_GETARG_DATUM(0), &paths, &template);
    PG_RETURN_JSONB_P(template);
}

Datum
pg_splitjson_paths(PG_FUNCTION_ARGS)
{
    Jsonb *paths;
    Jsonb *template;

    get_cold(PG_GETARG_DATUM(0), &paths, &template);
    PG_RETURN_JSONB_P(paths);
}

Datum
pg_splitjson_assert_object_path(PG_FUNCTION_ARGS)
{
    ArrayType *array = PG_GETARG_ARRAYTYPE_P(1);
    Datum *keys;
    bool *nulls;
    int count;
    int i;

    if (ARR_NDIM(array) > 1)
        invalid_path("update path must be a one-dimensional text array");
    deconstruct_array(array, TEXTOID, -1, false, TYPALIGN_INT, &keys, &nulls, &count);
    if (count == 0 || count > MAX_DEPTH)
        invalid_path("update path depth must be between 1 and 64");
    for (i = 0; i < count; i++)
        if (nulls[i])
            invalid_path("update path must not contain SQL NULL segments");
    PG_RETURN_VOID();
}

/* Read object keys only, matching extraction semantics even at array nodes. */
Datum
pg_splitjson_object_field(PG_FUNCTION_ARGS)
{
    Jsonb *doc = PG_GETARG_JSONB_P(0);
    ArrayType *array = PG_GETARG_ARRAYTYPE_P(1);
    Datum *keys;
    bool *nulls;
    Path path;
    JsonbValue value;
    int i;

    if (ARR_NDIM(array) > 1)
        invalid_path("read path must be a one-dimensional text array");
    deconstruct_array(array, TEXTOID, -1, false, TYPALIGN_INT,
                      &keys, &nulls, &path.depth);
    if (path.depth == 0 || path.depth > MAX_DEPTH)
        invalid_path("read path depth must be between 1 and 64");
    path.keys = palloc(sizeof(JsonbValue) * path.depth);
    path.sqlpath = NULL;
    for (i = 0; i < path.depth; i++)
    {
        text *key;

        if (nulls[i])
            invalid_path("read path must not contain SQL NULL segments");
        key = DatumGetTextPP(keys[i]);
        path.keys[i].type = jbvString;
        path.keys[i].val.string.val = VARDATA_ANY(key);
        path.keys[i].val.string.len = VARSIZE_ANY_EXHDR(key);
    }
    if (lookup_object_path(doc, &path, &value) == NULL)
        PG_RETURN_NULL();
    PG_RETURN_JSONB_P(JsonbValueToJsonb(&value));
}

/* Parse a type declaration, never interpolate caller-supplied SQL syntax. */
Datum
pg_splitjson_column_type(PG_FUNCTION_ARGS)
{
    char *declaration = text_to_cstring(PG_GETARG_TEXT_PP(0));
    Oid type_oid;
    int32 typmod;
    char *normalized;

    parseTypeString(declaration, &type_oid, &typmod, NULL);
    if (get_typtype(type_oid) == 'p')
        invalid_path("pseudo types are not valid business column types");
    normalized = format_type_extended(type_oid, typmod,
                                       FORMAT_TYPE_TYPEMOD_GIVEN | FORMAT_TYPE_FORCE_QUALIFY);
    PG_RETURN_TEXT_P(cstring_to_text(normalized));
}


/* Native text operation paths may match typed declared indexes. Negative indexes
 * require the actual container length and therefore use a hot ancestor/fallback. */
static bool
operation_prefix(const Path *path, Datum *keys, int depth)
{
    int i;

    if (path->depth > depth)
        return false;
    for (i = 0; i < path->depth; i++)
    {
        text *segment = DatumGetTextPP(keys[i]);
        JsonbValue *key = &path->keys[i];

        if (key->type == jbvString)
        {
            if (key->val.string.len != VARSIZE_ANY_EXHDR(segment) ||
                memcmp(key->val.string.val, VARDATA_ANY(segment), key->val.string.len) != 0)
                return false;
        }
        else
        {
            char *str = text_to_cstring(segment);
            char *end;
            long parsed;
            int32 declared = DatumGetInt32(DirectFunctionCall1(numeric_int4,
                                                    NumericGetDatum(key->val.numeric)));

            errno = 0;
            parsed = strtol(str, &end, 10);
            if (errno != 0 || end == str || *end != '\0' || parsed < 0 ||
                parsed > PG_INT32_MAX || parsed != declared)
                return false;
        }
    }
    return true;
}

static void
operation_array(ArrayType *array, Datum **keys, int *depth)
{
    bool *nulls;
    int i;

    if (ARR_NDIM(array) > 1)
        invalid_path("operation paths must be one-dimensional");
    deconstruct_array(array, TEXTOID, -1, false, TYPALIGN_INT, keys, &nulls, depth);
    if (*depth == 0 || *depth > MAX_DEPTH)
        invalid_path("operation path depth must be between 1 and 64");
    for (i = 0; i < *depth; i++)
        if (nulls[i])
            invalid_path("operation paths must not contain SQL NULL");
}

Datum
pg_splitjson_hot_route(PG_FUNCTION_ARGS)
{
    Paths paths = parse_paths(PG_GETARG_JSONB_P(0), true);
    Datum *keys;
    int depth;
    Datum *values;
    bool *nulls;
    int count;
    int i;
    int result = 0;

    operation_array(PG_GETARG_ARRAYTYPE_P(1), &keys, &depth);
    deconstruct_array(PG_GETARG_ARRAYTYPE_P(2), JSONBOID, -1, false, TYPALIGN_INT,
                      &values, &nulls, &count);
    if (count != paths.count)
        invalid_path("hot value count must match path declarations");
    for (i = 0; i < count; i++)
        if (!nulls[i] && operation_prefix(&paths.items[i], keys, depth) &&
            (paths.items[i].depth == depth || !JB_ROOT_IS_SCALAR(DatumGetJsonbP(values[i]))))
        {
            if (result != 0)
                ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("ambiguous present hot paths")));
            result = i + 1;
        }
    if (result == 0)
        PG_RETURN_NULL();
    PG_RETURN_INT32(result);
}

Datum
pg_splitjson_path_candidates(PG_FUNCTION_ARGS)
{
    Paths paths = parse_paths(PG_GETARG_JSONB_P(0), true);
    Datum *keys;
    int depth;
    Datum slots[MAX_PATHS];
    int count = 0;
    int i;

    operation_array(PG_GETARG_ARRAYTYPE_P(1), &keys, &depth);
    for (i = 0; i < paths.count; i++)
        if (paths.items[i].depth == depth && operation_prefix(&paths.items[i], keys, depth))
            slots[count++] = Int32GetDatum(i + 1);
    PG_RETURN_ARRAYTYPE_P(construct_array(slots, count, INT4OID, 4, true, TYPALIGN_INT));
}

/* Protect extension/configuration schemas before their own event triggers can
 * be removed. All checks target this extension; unrelated DROP is unaffected. */
Datum
pg_splitjson_ddl_start_guard(PG_FUNCTION_ARGS)
{
    EventTriggerData *event;
    DropStmt *drop;
    bool protected = false;
    ListCell *lc;

    if (!CALLED_AS_EVENT_TRIGGER(fcinfo))
        ereport(ERROR, (errcode(ERRCODE_E_R_I_E_EVENT_TRIGGER_PROTOCOL_VIOLATED),
                        errmsg("must be called as an event trigger")));
    event = (EventTriggerData *) fcinfo->context;
    if (!IsA(event->parsetree, DropStmt))
        PG_RETURN_NULL();
    drop = (DropStmt *) event->parsetree;
    if (drop->removeType != OBJECT_EXTENSION && drop->removeType != OBJECT_SCHEMA)
        PG_RETURN_NULL();
    foreach(lc, drop->objects)
    {
        Node *object = lfirst(lc);
        const char *name;

        if (IsA(object, String))
            name = strVal(object);
        else if (IsA(object, List) && list_length((List *) object) == 1 &&
                 IsA(linitial((List *) object), String))
            name = strVal(linitial((List *) object));
        else
            continue;
        if ((drop->removeType == OBJECT_EXTENSION && strcmp(name, "pg_splitjson") == 0) ||
            (drop->removeType == OBJECT_SCHEMA &&
             (strcmp(name, "splitjson") == 0 || strcmp(name, "splitjson_storage") == 0)))
            protected = true;
    }
    if (protected)
    {
        bool exists;

        if (SPI_connect() != SPI_OK_CONNECT)
            elog(ERROR, "SPI_connect failed");
        if (SPI_execute("SELECT 1 FROM splitjson._tables LIMIT 1", true, 1) != SPI_OK_SELECT)
            elog(ERROR, "managed relation check failed");
        exists = SPI_processed > 0;
        SPI_finish();
        if (exists)
            ereport(ERROR, (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                            errmsg("remove managed relations with splitjson.drop_table before dropping the extension or its schemas")));
    }
    PG_RETURN_NULL();
}

/* Portable wire format: one protocol byte followed by validated text envelope.
 * No PostgreSQL JSONB physical bytes are accepted from a client. */
Datum
pg_splitjson_cold_send(PG_FUNCTION_ARGS)
{
    StringInfoData buffer;
    char *wire = DatumGetCString(DirectFunctionCall1(pg_splitjson_cold_out, PG_GETARG_DATUM(0)));

    pq_begintypsend(&buffer);
    pq_sendbyte(&buffer, 1);
    pq_sendtext(&buffer, wire, strlen(wire));
    PG_RETURN_BYTEA_P(pq_endtypsend(&buffer));
}

Datum
pg_splitjson_cold_recv(PG_FUNCTION_ARGS)
{
    StringInfo buffer = (StringInfo) PG_GETARG_POINTER(0);
    int remaining;
    int converted;
    char *wire;

    if (pq_getmsgbyte(buffer) != 1)
        ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                        errmsg("unsupported cold wire version")));
    remaining = buffer->len - buffer->cursor;
    wire = pq_getmsgtext(buffer, remaining, &converted);
    if ((int) strlen(wire) != converted)
        ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                        errmsg("cold wire text must not contain zero bytes")));
    pq_getmsgend(buffer);
    PG_RETURN_DATUM(DirectFunctionCall1(pg_splitjson_cold_in, CStringGetDatum(wire)));
}
