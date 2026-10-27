#!/usr/bin/env bash
# E6: the edge that crosses shards.
#
# stock_movement is co-located with the warehouse that performed it, but each
# movement may reference an order owned by a customer in another jurisdiction.
# The foreign key was dropped on the shards; this checks what that costs and
# whether the reference still resolves with the router in front.
#
#   bash experiments/e6_cross_shard_reference.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
declare -A PORT=([eu]=5441 [uk]=5442 [us]=5443)

echo "== per shard: movements whose order is not stored here"
for s in eu uk us; do
  "$PGBIN/psql" -h 127.0.0.1 -p "${PORT[$s]}" -U postgres -d "shopstack_$s" -tAq -F ' | ' -c "
    SELECT '$s',
           count(*) FILTER (WHERE ref_order_id IS NOT NULL)            AS with_reference,
           count(*) FILTER (WHERE ref_order_id IS NOT NULL
                              AND o.order_id IS NULL)                  AS resolvable_only_elsewhere
    FROM stock_movement m
    LEFT JOIN customer_order o ON o.order_id = m.ref_order_id;"
done

echo
echo "== the router: do those references exist on another shard?"
"$PGBIN/psql" -h 127.0.0.1 -p 5433 -U postgres -d shopstack_router -c "
  WITH orphan AS (
    SELECT m.movement_id, m.ref_order_id
    FROM movement_all m
    WHERE m.ref_order_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM order_all o WHERE o.order_id = m.ref_order_id)
    LIMIT 1000
  )
  SELECT count(*) AS orphaned_sample,
         count(*) FILTER (WHERE ref_order_id IS NULL) AS impossible
  FROM orphan;"

echo
echo "== three examples: movement on one shard, order on another"
"$PGBIN/psql" -h 127.0.0.1 -p 5433 -U postgres -d shopstack_router -c "
  SELECT m.shard AS movement_shard, o.shard AS order_shard,
         m.movement_id, m.warehouse_id, m.ref_order_id
  FROM movement_all m
  JOIN order_all o ON o.order_id = m.ref_order_id
  WHERE m.shard <> o.shard
  LIMIT 3;"
