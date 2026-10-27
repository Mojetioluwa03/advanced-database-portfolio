#!/usr/bin/env bash
# E3: the consistency window a read replica creates.
#
# Pausing replay on the standby widens an otherwise millisecond-wide window to
# something visible: the primary commits, the standby still serves the old value,
# and the replica lag is reported in bytes and seconds. Resuming measures how
# long catch-up takes.
#
#   bash experiments/e3_replication_lag.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
PRIMARY=5441
STANDBY=5444
DB=shopstack_eu

pri() { "$PGBIN/psql" -h 127.0.0.1 -p "$PRIMARY" -U postgres -d "$DB" -tAq -v ON_ERROR_STOP=1 -c "$1"; }
stb() { "$PGBIN/psql" -h 127.0.0.1 -p "$STANDBY" -U postgres -d "$DB" -tAq -v ON_ERROR_STOP=1 -c "$1"; }

IFS='|' read -r wh var qty <<<"$(pri "SELECT warehouse_id, variant_id, quantity FROM stock_level ORDER BY warehouse_id, variant_id LIMIT 1")"
echo "probe row: warehouse $wh variant $var, quantity $qty"

echo
echo "== 1. stop the standby from applying WAL"
stb "SELECT pg_wal_replay_resume()" >/dev/null 2>&1 || true
stb "SELECT pg_wal_replay_pause()" >/dev/null
echo "replay paused: $(stb 'SELECT pg_is_wal_replay_paused()')"

echo
echo "== 2. commit a write on the primary"
pri "UPDATE stock_level SET quantity = quantity + 1000 WHERE warehouse_id = $wh AND variant_id = $var" >/dev/null
echo "primary quantity    : $(pri "SELECT quantity FROM stock_level WHERE warehouse_id=$wh AND variant_id=$var")"
echo "standby quantity    : $(stb "SELECT quantity FROM stock_level WHERE warehouse_id=$wh AND variant_id=$var")  <- stale"

echo
echo "== 3. how far behind is the standby?"
plsn=$(pri "SELECT pg_current_wal_lsn()")
slsn=$(stb "SELECT pg_last_wal_replay_lsn()")
echo "primary wal lsn     : $plsn"
echo "standby replay lsn  : $slsn"
echo "lag bytes           : $(pri "SELECT pg_wal_lsn_diff('$plsn', '$slsn')")"
echo "sender view         : $(pri "SELECT state || ', replay_lag ' || COALESCE(replay_lag::text, 'n/a') FROM pg_stat_replication")"

echo
echo "== 4. resume and time the catch-up"
start=$(date +%s%N)
stb "SELECT pg_wal_replay_resume()" >/dev/null
for _ in $(seq 1 200); do
  [ "$(stb "SELECT pg_last_wal_replay_lsn() >= '$plsn'")" = "t" ] && break
  sleep 0.05
done
end=$(date +%s%N)
echo "catch-up            : $(( (end - start) / 1000000 )) ms"
echo "standby quantity    : $(stb "SELECT quantity FROM stock_level WHERE warehouse_id=$wh AND variant_id=$var")  <- caught up"
echo "lag bytes after     : $(pri "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '$(stb "SELECT pg_last_wal_replay_lsn()")')")"

echo
echo "== 5. restore the probe row"
pri "UPDATE stock_level SET quantity = quantity - 1000 WHERE warehouse_id = $wh AND variant_id = $var" >/dev/null
echo "quantity back to    : $(pri "SELECT quantity FROM stock_level WHERE warehouse_id=$wh AND variant_id=$var")"
