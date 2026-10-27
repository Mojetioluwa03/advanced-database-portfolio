#!/usr/bin/env bash
# Streaming replica of the EU shard.
#
#   bash replication/setup_replica.sh          # create and start the standby
#   bash replication/setup_replica.sh --rebuild # wipe and re-clone
#
# The EU primary already runs with wal_level=replica, max_wal_senders=5 and
# wal_keep_size=64MB (set by shard/build_shards.sh). pg_basebackup -R writes
# primary_conninfo and the standby.signal for us, so the clone starts in
# recovery without hand-editing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
PRIMARY_PORT=5441
STANDBY_PORT=5444
STANDBY="$WS/.pgshards/eu-standby/data"

if [ "${1:-}" = "--rebuild" ] && [ -d "$STANDBY" ]; then
  "$PGBIN/pg_ctl" -D "$STANDBY" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WS/.pgshards/eu-standby"
fi

mkdir -p "$(dirname "$STANDBY")"

if [ ! -d "$STANDBY" ]; then
  echo "== cloning EU primary with pg_basebackup"
  "$PGBIN/pg_basebackup" -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres \
    -D "$STANDBY" -R -X stream -c fast -P
  printf 'port = %s\n' "$STANDBY_PORT" >> "$STANDBY/postgresql.conf"
fi

if ! "$PGBIN/pg_ctl" -D "$STANDBY" status >/dev/null 2>&1; then
  "$PGBIN/pg_ctl" -D "$STANDBY" -l "$WS/.pgshards/eu-standby/server.log" -w start >/dev/null
fi

echo "== standby state"
"$PGBIN/psql" -h 127.0.0.1 -p "$STANDBY_PORT" -U postgres -d shopstack_eu -c "
  SELECT pg_is_in_recovery() AS in_recovery,
         pg_last_wal_replay_lsn() AS replay_lsn,
         pg_last_wal_receive_lsn() AS receive_lsn;"

echo "== primary sender state"
"$PGBIN/psql" -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d shopstack_eu -c "
  SELECT application_name, state, sync_state,
         client_addr, write_lag, flush_lag, replay_lag
  FROM pg_stat_replication;"
