# Shared plumbing for the two-session demonstrations.
#
# Sourced, not run. It fixes the connection settings, resets the P3 fixture,
# prints the stock/ledger state, and runs two session scripts concurrently while
# stamping every output line with its offset from the start of the race, so the
# transcript shows what actually overlapped in time.
#
#   source lib.sh          # from a demo script in concurrency/

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"

PSQL=${PSQL_BIN:-../../../.pg16/pgsql/bin/psql}
PGHOST=${PGHOST:-localhost}
PGPORT=${PGPORT:-5433}
PGUSER=${PGUSER:-postgres}
PGDATABASE=${PGDATABASE:-shopstack}
export PGHOST PGPORT PGUSER PGDATABASE

sql() {
    "$PSQL" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

stamp() {
    local start=$1 now line
    while IFS= read -r line; do
        now=${EPOCHREALTIME//[.,]/}
        printf '[%5d ms] %s\n' "$(( (now - start) / 1000 ))" "$line"
    done
}

now_us() { echo "${EPOCHREALTIME//[.,]/}"; }

reset_fixture() {
    sql -q -f "$root/setup_test_data.sql"
}

# Put a known number of units on hand for the race variant. Kept below the
# fixture's 10 so the sums in the transcript are easy to check by eye.
#   set_stock 1                          # first test warehouse
#   set_stock 1 'P3 test warehouse 2'    # a named warehouse
set_stock() {
    local qty=$1 wh=${2:-P3 test warehouse}
    sql -q -v qty="$qty" -v wh="$wh" <<'SQL'
        UPDATE stock_level
           SET quantity = :'qty'::int, updated_at = now()
         WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
           AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = :'wh');
SQL
}

STATE_SQL=$(cat <<'SQL'
SELECT sl.quantity AS on_hand,
       (SELECT count(*) FROM customer_order o
         WHERE o.customer_id = c.customer_id) AS orders,
       (SELECT count(*) FROM stock_movement m
         WHERE m.variant_id = v.variant_id AND m.reason = 'sale') AS sale_movements,
       (SELECT coalesce(sum(m.delta), 0) FROM stock_movement m
         WHERE m.variant_id = v.variant_id AND m.reason = 'sale') AS units_sold
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
JOIN customer c ON c.email = 'p3.tester@example.test'
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';
SQL
)

ORDERS_SQL=$(cat <<'SQL'
SELECT o.order_id, o.status, l.quantity AS units,
       m.delta, m.reason
FROM customer_order o
JOIN order_line l ON l.order_id = o.order_id
LEFT JOIN stock_movement m ON m.ref_order_id = o.order_id AND m.reason = 'sale'
WHERE o.customer_id = (SELECT customer_id FROM customer WHERE email = 'p3.tester@example.test')
ORDER BY o.order_id;
SQL
)

show_state()  { sql -c "$STATE_SQL"; }
show_orders() { sql -c "$ORDERS_SQL"; }

show_warehouses() {
    sql -c "
        SELECT w.name AS warehouse, sl.quantity AS on_hand
        FROM stock_level sl
        JOIN product_variant v USING (variant_id)
        JOIN warehouse w USING (warehouse_id)
        WHERE v.sku = 'P3-RACE-SKU'
        ORDER BY w.name"
}

show_ledger() {
    sql -c "
        SELECT m.reason, count(*) AS rows, sum(m.delta) AS units
        FROM stock_movement m
        JOIN product_variant v USING (variant_id)
        WHERE v.sku = 'P3-RACE-SKU'
        GROUP BY m.reason
        ORDER BY m.reason"
}

# Run two session scripts against the same fixture. A starts immediately, B
# 0.4s later: long enough for A to have read but not committed, short enough
# that both sessions overlap. Extra arguments are forwarded to both psql
# invocations, which is how a demo passes -v iso="repeatable read".
run_sessions() {
    local a=$1 b=$2 pa pb sa=0 sb=0 start
    shift 2
    start=$(now_us)

    echo "--- session A: sessions/$a (starts at 0 ms) ---"
    sql "$@" -f "sessions/$a" 2>&1 | stamp "$start" > "$TMP/a.log" &
    pa=$!
    sleep 0.4
    echo "--- session B: sessions/$b (starts at 400 ms) ---"
    sql "$@" -f "sessions/$b" 2>&1 | stamp "$start" > "$TMP/b.log" &
    pb=$!

    wait "$pa" || sa=$?
    wait "$pb" || sb=$?
    cat "$TMP/a.log" "$TMP/b.log"
    echo "--- psql exit status: A=$sa B=$sb ---"

    RACE_STATUS_A=$sa
    RACE_STATUS_B=$sb
}
