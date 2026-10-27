#!/usr/bin/env bash
# Build the three regional shards from the single-node Portfolio 1 database.
#
#   bash shard/build_shards.sh
#
# Creates (once) a data directory per shard under .pgshards/, starts each on its
# own port, applies the Portfolio 1 schema, and loads that jurisdiction's slice.
# Re-running rebuilds the databases but keeps the data directories.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"          # workspace root: holds .pg16 and .pgdata
PGBIN="$WS/.pg16/pgsql/bin"
HERE="$ROOT/portfolio-5-distributed-cloud"
SHARD_ROOT="$WS/.pgshards"
SRC_PORT=5433
SRC_DB=shopstack

port_of() { case "$1" in eu) echo 5441 ;; uk) echo 5442 ;; us) echo 5443 ;; *) exit 1 ;; esac; }

echo "== 1/4 build owner mapping in the source database"
"$PGBIN/psql" -h 127.0.0.1 -p "$SRC_PORT" -U postgres -d "$SRC_DB" \
  -v ON_ERROR_STOP=1 -q -f "$HERE/shard/prepare_source.sql"

for s in eu uk us; do
  port="$(port_of "$s")"
  data="$SHARD_ROOT/$s/data"
  csv="$SHARD_ROOT/$s/csv"
  mkdir -p "$csv"

  echo "== [$s] cluster on port $port"
  if [ ! -d "$data" ]; then
    "$PGBIN/initdb" -D "$data" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
    cat >> "$data/postgresql.conf" <<EOF
port = $port
listen_addresses = '127.0.0.1'
wal_level = replica
max_wal_senders = 5
wal_keep_size = 64MB
EOF
  fi

  if ! "$PGBIN/pg_ctl" -D "$data" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$data" -l "$SHARD_ROOT/$s/server.log" -w start >/dev/null
  fi

  echo "== [$s] extract slice from $SRC_DB"
  "$PGBIN/psql" -h 127.0.0.1 -p "$SRC_PORT" -U postgres -d "$SRC_DB" \
    -v ON_ERROR_STOP=1 -q \
    -v outdir="$(cygpath -m "$csv")" \
    -c "SET shard.name = '$s'" \
    -f "$HERE/shard/extract.sql"

  echo "== [$s] create schema and load"
  "$PGBIN/dropdb"  -h 127.0.0.1 -p "$port" -U postgres --if-exists "shopstack_$s"
  "$PGBIN/createdb" -h 127.0.0.1 -p "$port" -U postgres "shopstack_$s"
  "$PGBIN/psql" -h 127.0.0.1 -p "$port" -U postgres -d "shopstack_$s" \
    -q -v ON_ERROR_STOP=1 -f "$HERE/../portfolio-1-database-design/schema.sql" >/dev/null
  "$PGBIN/psql" -h 127.0.0.1 -p "$port" -U postgres -d "shopstack_$s" \
    -q -v ON_ERROR_STOP=1 -v indir="$(cygpath -m "$csv")" \
    -f "$HERE/shard/load.sql" >/dev/null
done

echo
echo "== row counts per shard"
for s in eu uk us; do
  port="$(port_of "$s")"
  echo "-- $s (port $port)"
  "$PGBIN/psql" -h 127.0.0.1 -p "$port" -U postgres -d "shopstack_$s" -c "
    SELECT 'customer' AS t, count(*) FROM customer
    UNION ALL SELECT 'customer_order', count(*) FROM customer_order
    UNION ALL SELECT 'order_line', count(*) FROM order_line
    UNION ALL SELECT 'product_variant', count(*) FROM product_variant
    UNION ALL SELECT 'stock_movement', count(*) FROM stock_movement;"
done
