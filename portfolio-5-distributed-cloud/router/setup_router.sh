#!/usr/bin/env bash
# Create the router database and its foreign tables.
#   bash router/setup_router.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
PORT=5433
DB=shopstack_router

"$PGBIN/dropdb"   -h 127.0.0.1 -p "$PORT" -U postgres --if-exists "$DB"
"$PGBIN/createdb" -h 127.0.0.1 -p "$PORT" -U postgres "$DB"
"$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 \
  -f "$ROOT/portfolio-1-database-design/schema.sql" >/dev/null
"$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 \
  -f "$ROOT/portfolio-5-distributed-cloud/router/setup_router.sql"

echo "== foreign tables reachable"
"$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -c "
  SELECT 'orders' AS v, count(*) FROM order_all
  UNION ALL SELECT 'customers', count(*) FROM customer_all
  UNION ALL SELECT 'stock rows', count(*) FROM stock_all
  UNION ALL SELECT 'movements', count(*) FROM movement_all;"
