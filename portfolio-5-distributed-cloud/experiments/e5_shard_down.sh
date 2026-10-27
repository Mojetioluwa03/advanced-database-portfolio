#!/usr/bin/env bash
# E5: one shard down stops the queries that need it, and only those.
#
#   bash experiments/e5_shard_down.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
ROUTER=("$PGBIN/psql" -h 127.0.0.1 -p 5433 -U postgres -d shopstack_router -tAq)
US_DATA="$WS/.pgshards/us/data"

router() { "${ROUTER[@]}" -c "$1" 2>&1 | head -3; }

echo "== 1. all shards up"
echo "customers via view  : $(router 'SELECT count(*) FROM customer_all')"
echo "EU-routed orders    : $(router "SELECT count(*) FROM shard.order_eu")"

echo
echo "== 2. stop the US shard (port 5443)"
"$PGBIN/pg_ctl" -D "$US_DATA" -m fast -w stop >/dev/null
echo "US status           : $("$PGBIN/pg_ctl" -D "$US_DATA" status 2>&1 | head -1)"

echo
echo "== 3. a query that knows its jurisdiction still works"
echo "EU-routed orders    : $(router "SELECT count(*) FROM shard.order_eu")"

echo
echo "== 4. a request for US data cannot be served"
echo "US-routed orders    : $(router "SELECT count(*) FROM shard.order_us")"

echo
echo "== 5. and the fan-out view fails as a whole"
echo "customers via view  : $(router 'SELECT count(*) FROM customer_all')"

echo
echo "== 6. restart the shard"
"$PGBIN/pg_ctl" -D "$US_DATA" -l "$WS/.pgshards/us/server.log" -w start >/dev/null
echo "US-routed orders    : $(router "SELECT count(*) FROM shard.order_us")"
echo "customers via view  : $(router 'SELECT count(*) FROM customer_all')"
