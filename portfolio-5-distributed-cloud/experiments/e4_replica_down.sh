#!/usr/bin/env bash
# E4: the primary does not need the standby, but the standby's readers need it.
#
#   bash experiments/e4_replica_down.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
PRIMARY=5441
STANDBY=5444
DB=shopstack_eu
DATA="$WS/.pgshards/eu-standby/data"

pri() { "$PGBIN/psql" -h 127.0.0.1 -p "$PRIMARY" -U postgres -d "$DB" -tAq -c "$1" 2>&1; }
stb() { "$PGBIN/psql" -h 127.0.0.1 -p "$STANDBY" -U postgres -d "$DB" -tAq -c "$1" 2>&1; }

echo "== 1. both alive"
echo "standby in recovery : $(stb 'SELECT pg_is_in_recovery()')"
echo "replication senders : $(pri 'SELECT count(*) FROM pg_stat_replication')"

echo
echo "== 2. stop the standby"
"$PGBIN/pg_ctl" -D "$DATA" -m fast -w stop >/dev/null
echo "standby status      : $("$PGBIN/pg_ctl" -D "$DATA" status 2>&1 | head -1)"

echo
echo "== 3. does the primary still take writes?"
pri "UPDATE stock_level SET quantity = quantity + 1 WHERE warehouse_id = 3 AND variant_id = 3" >/dev/null
echo "write accepted      : $(pri 'SELECT quantity FROM stock_level WHERE warehouse_id = 3 AND variant_id = 3')"
echo "replication senders : $(pri 'SELECT count(*) FROM pg_stat_replication')   <- replica gone, writes continue"
pri "UPDATE stock_level SET quantity = quantity - 1 WHERE warehouse_id = 3 AND variant_id = 3" >/dev/null

echo
echo "== 4. what a report query sees now"
echo "reading the standby : $(stb 'SELECT count(*) FROM customer_order' | head -2)"

echo
echo "== 5. restart and catch up"
"$PGBIN/pg_ctl" -D "$DATA" -l "$WS/.pgshards/eu-standby/server.log" -w start >/dev/null
for _ in $(seq 1 100); do
  [ "$(stb 'SELECT pg_is_in_recovery()')" = "t" ] && break
  sleep 0.1
done
echo "standby rows        : $(stb 'SELECT count(*) FROM customer_order')"
echo "lag bytes           : $(pri "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '$(stb 'SELECT pg_last_wal_replay_lsn()')')")"
