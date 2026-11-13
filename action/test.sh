#!/usr/bin/env bash
# Local test of the action's script against the dev cluster (no GitHub needed).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
(cd cli && go build -o "$ROOT/build/gnomon" ./cmd/gnomon)
export PGHOST=$ROOT/build PGPORT=${PGPORT:-54329} PGUSER=postgres
DB=action_test
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
psql -X -q -d $DB -c "set client_min_messages=warning" -c "create extension gnomon" \
  -c "create table t (id int primary key, v int)" -c "insert into t values (1, 1)" -c "select gnomon.track('t')" >/dev/null
export GNOMON_BIN=$ROOT/build/gnomon GNOMON_DSN="host=$PGHOST port=$PGPORT user=postgres dbname=$DB" PR_NUMBER=42 PR_ACTION=opened
export GITHUB_OUTPUT=$(mktemp)
bash action/run.sh
grep -q '^branch=pr-42$' "$GITHUB_OUTPUT"
url=$(sed -n "s/^database-url=//p" "$GITHUB_OUTPUT")
# "migrations and tests" run against the branch URL
psql -X -q "$url" -c "update t set v = 2 where id = 1" -c "insert into t values (2, 2)"
[ "$(psql -X -At "$url" -c 'select v from t where id = 1')" = 2 ]
[ "$(psql -X -At -d $DB -c 'select v from t where id = 1')" = 1 ]
bash action/run.sh >/dev/null                                 # idempotent on synchronize
GNOMON_MODE=comment bash action/run.sh | tee /dev/stderr | grep -q '| t | 1 | 1 | 0 |'
# migrations: DDL on the branch only, named in the comment
mdir=$(mktemp -d)
printf "alter table t add column note text default 'n';\nupdate t set note = 'pr' where id = 1;\n" > "$mdir/001.sql"
GNOMON_MIGRATIONS="$mdir/*.sql" bash action/run.sh >/dev/null
url=$(sed -n "s/^database-url=//p" "$GITHUB_OUTPUT" | tail -1)
[ "$(psql -X -At "$url" -c 'select note from t where id = 1')" = pr ] || { echo "FAILED: migration on the branch"; exit 1; }
[ "$(psql -X -At -d $DB -c "select count(*) from information_schema.columns where table_schema = 'public' and table_name = 't' and column_name = 'note'")" = 0 ]
GNOMON_MODE=comment bash action/run.sh | grep -q '| add_column | public.t | `note` | text |' || { echo "FAILED: schema changes in the comment"; exit 1; }
rm -rf "$mdir"
PR_ACTION=closed bash action/run.sh | grep -q "dropped branch pr-42"
[ "$(psql -X -At -d $DB -c "select count(*) from gnomon.branch where name = 'pr-42'")" = 0 ]
PR_ACTION=closed bash action/run.sh | grep -q "already dropped"   # closing twice is fine
# a connection URL instead of key=value settings, and an explicit branch name
GNOMON_DSN="postgresql://postgres@/$DB?host=$PGHOST&port=$PGPORT" GNOMON_BRANCH=from-url PR_ACTION=opened bash action/run.sh >/dev/null
url=$(sed -n "s/^database-url=//p" "$GITHUB_OUTPUT" | tail -1)
psql -X -q "$url" -c "update t set v = 3 where id = 1"
[ "$(psql -X -At "$url" -c 'select v from t where id = 1')" = 3 ] || { echo "FAILED: URL input"; exit 1; }
[ "$(psql -X -At -d $DB -c 'select v from t where id = 1')" = 1 ]
# the C module recipe: options carry the branch setting alone
GNOMON_C_MODULE=true GNOMON_BRANCH=c-recipe PR_ACTION=opened bash action/run.sh >/dev/null
opts=$(sed -n "s/^options=//p" "$GITHUB_OUTPUT" | tail -1)
[ "$opts" = "-c gnomon.branch=c-recipe" ] || { echo "FAILED: c-module options: $opts"; exit 1; }
psql -X -q -d postgres -c "drop database $DB" >/dev/null
echo ok
