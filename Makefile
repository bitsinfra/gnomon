# Gnomon build.
#   make            build sql/gnomon--$(GN_VERSION).sql (the C module: make -C src/c)
#   make install    install into the PostgreSQL found by PG_CONFIG (PGXS)
#   make dev        install into build/ext for the local test cluster (extension_control_path)
#   make test       run the test suite against a throwaway cluster
GN_VERSION := $(shell sed -n "s/^default_version = '\(.*\)'/\1/p" gnomon.control)
EXTENSION  = gnomon
SQL_SRC    = $(sort $(wildcard src/sql/*.sql))
PREVIOUS_VERSION = 1.0.0
UPGRADE_SQL = sql/gnomon--$(PREVIOUS_VERSION)--$(GN_VERSION).sql
DATA_built = sql/gnomon--$(GN_VERSION).sql $(UPGRADE_SQL)
PG_CONFIG ?= pg_config

all: $(DATA_built)

$(UPGRADE_SQL): sql/gnomon--$(GN_VERSION).sql tools/build_upgrade.py tools/sqlsplit.py $(wildcard src/upgrade/*.sql)
	python3 tools/build_upgrade.py $< $(PREVIOUS_VERSION) $(GN_VERSION) > $@.tmp && mv $@.tmp $@

sql/gnomon--$(GN_VERSION).sql: $(SQL_SRC) gnomon.control
	@mkdir -p sql
	@{ echo "-- Generated from src/sql by make; do not edit."; for f in $(SQL_SRC); do echo; echo "-- ==== $$f"; cat $$f; done; } > $@
	@sed -i.bak '1,/^\\echo/!{/^\\echo Use/d;}' $@ && rm -f $@.bak

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

dev: $(DATA_built)
	@mkdir -p build/ext/extension
	cp gnomon.control build/ext/extension/
	cp sql/gnomon--*.sql build/ext/extension/

test: dev
	./test/run.sh

.PHONY: dev test
