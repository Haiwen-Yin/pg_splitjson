/* Copyright 2026 PG SplitJSON contributors
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SPLITJSON_SECURITY_H
#define SPLITJSON_SECURITY_H

#include "executor/spi.h"
#include "nodes/parsenodes.h"

extern void splitjson_security_init(void);
extern void splitjson_security_fini(void);
extern Oid splitjson_extension_owner(void);
extern void splitjson_authorize_query(Query *query);
extern SPIPlanPtr splitjson_prepare_caller(const char *sql, int nargs, Oid *types,
                                          Oid caller, Oid storage);
extern Oid splitjson_entry_caller(void);

#endif
