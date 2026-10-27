#!/usr/bin/env bash
# E7: why the cross-shard edge needs a saga, not a distributed transaction.
#
# Checkout writes an order on the customer's shard and decrements stock on the
# warehouse's shard. If those could be prepared together, two-phase commit would
# make the pair atomic. postgres_fdw cannot: PREPARE TRANSACTION is refused once
# a foreign table has been touched, because the remote transaction has already
# run outside the local prepare. This records the refusal.
#
#   bash experiments/e7_no_two_phase_commit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
DB=shopstack_router

run() { "$PGBIN/psql" -h 127.0.0.1 -p 5433 -U postgres -d "$DB" -X "$@" 2>&1; }

echo "== 1. a write that touches the US shard, then a prepare"
run -c "BEGIN" \
    -c "UPDATE shard.stock_us SET quantity = quantity WHERE warehouse_id = -1" \
    -c "PREPARE TRANSACTION 'p5_probe'" || true

echo
echo "== 2. the prepare did not exist, so there is nothing to roll back"
run -tAq -c "ROLLBACK PREPARED 'p5_probe'" || true

echo
echo "== 3. the local half of the mechanism is off by default here"
echo -n "max_prepared_transactions on the router: "
"$PGBIN/psql" -h 127.0.0.1 -p 5433 -U postgres -d "$DB" -X -tAq \
  -c "SHOW max_prepared_transactions"
