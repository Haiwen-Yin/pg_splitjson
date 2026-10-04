EXTENSION = pg_splitjson
MODULE_big = pg_splitjson
OBJS = src/pg_splitjson.o src/query_rewrite.o
DATA = sql/pg_splitjson--0.1.0.sql
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
