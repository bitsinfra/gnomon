#!/usr/bin/env bash
# Version key ordering: a writer that waited on a row lock stamps a key above the lock
# holder's xid, so keys never decrease along a row's versions, at READ COMMITTED and REPEATABLE READ.
source "$(dirname "$0")/_lib.sh"
q -c "create table k(id int primary key, v int); insert into k values (1, 0); select gnomon.track('k');" >/dev/null
for iso in "read committed" "repeatable read"; do
  ( q -c "begin isolation level $iso" -c "update k set v = v + 1 where id = 1" -c "select pg_sleep(1)" -c "commit" >/dev/null ) &
  sleep 0.3
  psql -X -q -At -d "$DB" -c "begin isolation level $iso" -c "update k set v = v + 10 where id = 1" -c "commit" >/dev/null 2>&1 || true
  wait
done
bad=$(q -c "select count(*) from (select gn_key, lag(gn_key) over (order by gn_key, gn_lsn) p, (gn_key & 281474976710655) - gn_xoff as x,
                                          lag((gn_key & 281474976710655) - gn_xoff) over (order by gn_key, gn_lsn) px from _gnomon.k__v where gn_flags & 32 = 0) s
            where s.gn_key < s.p or (s.px is not null and (s.gn_key & 281474976710655) <= s.px)")
[ "$bad" = "0" ] || fail "$bad versions out of order"
echo ok
