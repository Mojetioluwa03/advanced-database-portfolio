#!/usr/bin/env bash
# 03 — deadlock: two sessions take the same two stock rows in opposite order.
#
# A locks warehouse 1 then asks for warehouse 2; B locks warehouse 2 then asks
# for warehouse 1. Neither can get its second lock, so PostgreSQL's deadlock
# detector fires after deadlock_timeout, aborts one transaction with SQLSTATE
# 40P01 and lets the other finish.
#
# Which session is the victim is not deterministic - it is whichever the
# detector reaches first - but the invariant is: exactly one commits, and its
# work is complete, because the victim's partial update was rolled back.
#
#   ./03_deadlock.sh                       # portable cluster on 5433
#
# Writes the whole transcript to ../evidence/03_deadlock.txt.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$root/evidence"

main() {
    echo "\$ concurrency/03_deadlock.sh"
    echo "PostgreSQL $("$PSQL" --version | awk '{print $3}'), $PGHOST:$PGPORT/$PGDATABASE"
    sql -c "SHOW deadlock_timeout"
    echo

    reset_fixture
    set_stock 1
    set_stock 1 'P3 test warehouse 2'
    echo "starting state: 1 unit in each warehouse, no orders, empty ledger"
    show_warehouses
    echo
    run_sessions deadlock_a.sql deadlock_b.sql
    echo
    echo "=== committed state after the deadlock ==="
    show_warehouses
    show_ledger
    echo
    echo "One session was aborted with 'deadlock detected' (SQLSTATE 40P01); its"
    echo "transaction ended, releasing its lock, and the survivor updated the row"
    echo "it was waiting for. Both rows are now 0, and the ledger holds exactly"
    echo "two rows totalling -2: the survivor's. The victim's first update and its"
    echo "first ledger row were rolled back, so nothing was counted twice."
}

main 2>&1 | tee "$root/evidence/03_deadlock.txt"
