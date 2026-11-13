#!/usr/bin/env bash
# History checker: three isolation levels on the dev cluster; then, on clusters of its
# own, kill -9 of the postmaster mid-run (durable commits), logged reads replayed on a
# synchronous standby, and a failover to that standby mid-run.
source "$(dirname "$0")/_cluster.sh"
(cd "$ROOT/cli" && go build -o "$ROOT/build/gnomon-histcheck" ./cmd/gnomon-histcheck)
HC="$ROOT/build/gnomon-histcheck"
V=${HC_VERIFY:-250}
# with GNOMON_C=1 (src/c/test/run.sh) the table is versioned by the C trigger
CM=(); [ -n "${GNOMON_C:-}" ] && CM=(--c-module)
for iso in "read committed" "repeatable read" "serializable"; do
  "$HC" --server "host=$ROOT/build port=${PGPORT:-54329} user=postgres" --duration "${HC_DURATION:-3s}" --iso "$iso" --verify-max "$V" ${CM[@]+"${CM[@]}"}
done
DUR="synchronous_commit = on
fsync = on"
# with the C module, the crash, replica and failover runs have it preloaded and use its trigger too
[ -n "${GNOMON_C:-}" ] && DUR="$DUR
shared_preload_libraries = 'gnomon_c'"
# kill -9 mid-run
tc_init hc-crash 54343 "" "$DUR"
"$HC" --server "host=$ROOT/build port=54343 user=postgres" --duration 6s --kill --pgdata "$(tc_dir hc-crash)" --verify-max "$V" ${CM[@]+"${CM[@]}"}
# a synchronous standby: commits are visible only once the standby has them, so every
# coordinate handed out on the primary replays on it, and on it once promoted
for run in replica failover; do
  tc_init hc-pri 54344 "" "$DUR" "synchronous_standby_names = 'hc_sb'"
  tc_standby hc_sb 54345 54344 "hot_standby_feedback = on"
  if [ $run = replica ]; then
    "$HC" --server "host=$ROOT/build port=54344 user=postgres" --duration 4s --verify-max "$V" ${CM[@]+"${CM[@]}"} \
      --replica "host=$ROOT/build port=54345 user=postgres"
  else
    "$HC" --server "host=$ROOT/build port=54344 user=postgres" --duration 6s --verify-max "$V" ${CM[@]+"${CM[@]}"} --failover \
      --pgdata "$(tc_dir hc-pri)" --standby-pgdata "$(tc_dir hc_sb)" --standby-server "host=$ROOT/build port=54345 user=postgres"
  fi
  "$(pg_config --bindir)/pg_ctl" -D "$(tc_dir hc_sb)" -m immediate stop >/dev/null 2>&1 || true
  "$(pg_config --bindir)/pg_ctl" -D "$(tc_dir hc-pri)" -m immediate stop >/dev/null 2>&1 || true
done
