EXTENSION = pg_splitjson
MODULE_big = pg_splitjson
OBJS = src/pg_splitjson.o src/query_rewrite.o
DATA = sql/pg_splitjson--0.1.0.sql sql/pg_splitjson--0.2.0.sql sql/pg_splitjson--0.1.0--0.2.0.sql
REGRESS = production
REGRESS_OPTS = --inputdir=tests
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

.PHONY: sql-check release
sql-check:
	python3 scripts/generate-sql.py --check

release:
	python3 scripts/package-release.py
