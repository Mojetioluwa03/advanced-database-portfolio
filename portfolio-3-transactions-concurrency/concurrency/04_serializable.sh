#!/usr/bin/env bash
# 04 — write skew, and the level that stops it.
#
# Two sessions each enforce the same rule: never let the combined on-hand of the
# two warehouses drop below 1, so a sale is allowed only when the total is >= 2.
# Each takes its unit out of a *different* warehouse. No row is updated twice, so
# row locks and lost-update detection see nothing; the invariant is nevertheless
# broken, because each transaction validated against a total the other changed.
#
#   REPEATABLE READ (control) - both sessions keep a pre-commit snapshot, both
#                               see a total of 2, both commit, total ends at 0.
#   SERIALIZABLE              - the read/write dependency cycle is detected and
#                               the second committer fails with SQLSTATE 40001.
#                               That is not a bug to hide: the caller retries, and
#                               the retry sees total 1 and refuses the sale.
#
#   ./04_serializable.sh                   # portable cluster on 5433
#
# Writes the whole transcript to ../evidence/04_serializable.txt.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$root/evidence"

prepare() {
    reset_fixture
    set_stock 1
    set_stock 1 'P3 test warehouse 2'
    echo "starting state: 1 unit in each warehouse, so the total is 2"
    show_warehouses
    echo
}

retry_session() {
    local script=$1 label=$2 status=0 start
    start=$(now_us)
    echo "--- retry: session $label re-runs $script (the caller's retry) ---"
    sql -v iso=serializable -f "sessions/$script" 2>&1 | stamp "$start" || status=$?
    echo "--- retry psql exit status: $status ---"
}

main() {
    echo "\$ concurrency/04_serializable.sh"
    echo "PostgreSQL $("$PSQL" --version | awk '{print $3}'), $PGHOST:$PGPORT/$PGDATABASE"
    echo

    echo "############ PHASE 1 - REPEATABLE READ (write skew gets through) ############"
    prepare
    run_sessions write_skew_a.sql write_skew_b.sql -v iso="repeatable read"
    echo
    echo "=== committed state ==="
    show_warehouses
    show_ledger
    echo
    echo "Both sessions committed and neither lost an update, yet the total fell"
    echo "from 2 to 0: each read a total of 2 that was true when it read it, and"
    echo "the two writes together broke the rule. Snapshot isolation cannot see"
    echo "this because the anomaly is across rows, not inside one."
    echo

    echo "############ PHASE 2 - SERIALIZABLE (the cycle is detected) ############"
    prepare
    run_sessions write_skew_a.sql write_skew_b.sql -v iso="serializable"
    echo
    echo "=== committed state: one commit, one 40001 ==="
    show_warehouses
    show_ledger
    echo

    if (( RACE_STATUS_B != 0 )); then
        echo "Session B (the second committer) was aborted with 40001. Retrying it:"
        echo
        retry_session write_skew_b.sql B
    elif (( RACE_STATUS_A != 0 )); then
        echo "Session A was aborted with 40001. Retrying it:"
        echo
        retry_session write_skew_a.sql A
    else
        echo "Neither session failed, which should not happen at SERIALIZABLE."
    fi
    echo
    echo "=== final state after the retry ==="
    show_warehouses
    show_ledger
    echo
    echo "The retry re-ran the same code, read the total of 1 left by the winner,"
    echo "and refused the sale. One unit was sold, one remains, and the invariant"
    echo "held. The price of SERIALIZABLE is that the losing transaction must be"
    echo "retried by the application; the price of REPEATABLE READ is a silently"
    echo "broken rule."
}

main 2>&1 | tee "$root/evidence/04_serializable.txt"
