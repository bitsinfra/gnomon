# The gnomon C module. Build with PGXS:
#   make -C src/c && make -C src/c install            (into the server's libdir)
#   make -C src/c dev                                  (into ../../build/lib for the dev clusters)
MODULE_big = gnomon_c
OBJS       = gnomon_c.o
EXTENSION  = gnomon_c
DATA       = gnomon_c--1.0.2.sql gnomon_c--1.0.0--1.0.1.sql gnomon_c--1.0.1--1.0.2.sql
PG_CONFIG ?= pg_config
PG_CPPFLAGS = -Wno-declaration-after-statement
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

DEV = ../../build
dev: all
	mkdir -p $(DEV)/lib $(DEV)/ext/extension
	# a new file, not an overwrite: macOS kills processes that map a code-signed file changed in place
	rm -f $(DEV)/lib/gnomon_c$(DLSUFFIX)
	cp gnomon_c$(DLSUFFIX) $(DEV)/lib/
	cp gnomon_c.control $(DATA) $(DEV)/ext/extension/
.PHONY: dev
