#!/usr/bin/env bash
# Measure the cost of the distributed layout.
#   bash experiments/bench_routing.sh
# Warm-up run, then three measured runs, median — the same discipline as
# Portfolios 2 and 4. Timings are server-side execution times from EXPLAIN.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PGBIN="$WS/.pg16/pgsql/bin"
OUT="$ROOT/portfolio-5-distributed-cloud/benchmarks/routing.csv"
PORT=5433

ROUTER=("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d shopstack_router -tAq -v ON_ERROR_STOP=1)
MONO=("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d shopstack -tAq -v ON_ERROR_STOP=1)

oid=$("${ROUTER[@]}" -c "SELECT min(order_id) FROM shard.order_us")
echo "point-lookup order_id = $oid"
printf 'query,run1_ms,run2_ms,run3_ms,median_ms\n' > "$OUT"

measure() { # label, sql, then the psql array to use
  # One discarded warm-up and three measured runs inside a single session: a
  # fresh psql process would pay ~35 ms of FDW connection setup per query and
  # report that instead of the query cost.
  local label="$1" sql="$2"; shift 2
  local script runs median
  script=$(mktemp)
  for _ in 0 1 2 3; do printf 'EXPLAIN (ANALYZE, COSTS OFF) %s;\n' "$sql"; done > "$script"
  runs=$("$@" -f "$script" | sed -n 's/^Execution Time: \([0-9.]*\) ms$/\1/p' | tail -3 | paste -sd, -)
  rm -f "$script"
  median=$(printf '%s\n' "$runs" | tr ',' '\n' | sort -n | sed -n '2p')
  printf '%s,%s,%s\n' "$label" "$runs" "$median" >> "$OUT"
  printf '%-20s %s ms\n' "$label" "$median"
}

# One shard, key known.
measure routed_point   "SELECT * FROM shard.order_us WHERE order_id = $oid"     "${ROUTER[@]}"
measure routed_count   "SELECT count(*) FROM shard.order_us"                   "${ROUTER[@]}"
# All three shards, key unknown: the fan-out view.
measure fanout_point   "SELECT * FROM order_all WHERE order_id = $oid"         "${ROUTER[@]}"
measure fanout_count   "SELECT count(*) FROM order_all"                        "${ROUTER[@]}"
measure fanout_group   "SELECT shard, count(*) FROM order_all GROUP BY shard"  "${ROUTER[@]}"
# All three shards, aggregating per shard and combining the partials.
measure router_count   "SELECT total_orders()"                                 "${ROUTER[@]}"
measure router_status  "SELECT count(*) FROM status_counts()"                  "${ROUTER[@]}"
# The single node the cluster replaced.
measure single_count   "SELECT count(*) FROM customer_order"                    "${MONO[@]}"
measure single_status  "SELECT count(*) FROM (SELECT status, count(*) FROM customer_order GROUP BY status) s" "${MONO[@]}"

echo "wrote $OUT"
