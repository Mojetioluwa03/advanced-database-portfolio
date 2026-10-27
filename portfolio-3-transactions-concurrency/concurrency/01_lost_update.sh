#!/usr/bin/env bash
# 01 — lost update: two sessions sell the last unit of the same variant.
#
# Phase 1 runs the naive read-modify-write checkout in both sessions. Both read
# on-hand = 1 before either commits, both write 0 back, and both orders end up
# paid: two units sold, one unit ever in stock.
#
# Phase 2 repeats the same two checkouts with SELECT ... FOR UPDATE. Session B
# now waits for A, re-reads the committed 0 and refuses the sale, so exactly one
# order survives.
#
# Phase 3 shows the fix that needs no explicit lock and no re-read: a guarded
# UPDATE ... WHERE quantity >= 1 decides inside the statement.
#
#   ./01_lost_update.sh                    # portable cluster on 5433
#   PGPORT=5432 ./01_lost_update.sh        # a server of your own
#
# Writes the whole transcript to ../evidence/01_lost_update.txt.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$root/evidence"

main() {
    echo "\$ concurrency/01_lost_update.sh"
    echo "PostgreSQL $("$PSQL" --version | awk '{print $3}'), $PGHOST:$PGPORT/$PGDATABASE"
    echo

    echo "############ PHASE 1 - naive read-modify-write (the bug) ############"
    reset_fixture
    set_stock 1
    echo "starting state: one unit on hand, no orders, empty ledger"
    show_state
    echo
    run_sessions lost_update_a.sql lost_update_b.sql
    echo
    echo "=== committed outcome of phase 1 ==="
    show_state
    show_orders
    echo
    echo "Two paid orders and two -1 sale movements from a single unit on hand:"
    echo "the second read erased the first write and the ledger now claims 2 units"
    echo "left the warehouse. The CHECK constraint never fired because neither"
    echo "session wrote a negative number - the arithmetic was done before the row"
    echo "was locked, not by the database."
    echo

    echo "############ PHASE 2 - SELECT ... FOR UPDATE (the fix) ############"
    reset_fixture
    set_stock 1
    echo "starting state: identical fixture"
    show_state
    echo
    run_sessions lost_update_a_locked.sql lost_update_b_locked.sql
    echo
    echo "=== committed outcome of phase 2 ==="
    show_state
    show_orders
    echo
    echo "Session B blocked from 400 ms until A committed at ~2 s, then read 0,"
    echo "refused the sale and rolled back. One unit sold, one order, ledger and"
    echo "stock agree."
    echo

    echo "############ PHASE 3 - guarded UPDATE, no explicit lock ############"
    reset_fixture
    set_stock 1
    echo "starting state: identical fixture"
    show_state
    echo
    run_sessions lost_update_a_atomic.sql lost_update_b_atomic.sql
    echo
    echo "=== committed outcome of phase 3 ==="
    show_state
    show_orders
    echo
    echo "Neither session read the stock to decide anything. The WHERE clause was"
    echo "evaluated by the database against the row version it was about to write,"
    echo "so B's guard matched no row. Same outcome as phase 2, one statement"
    echo "instead of two, and no lock held across the 2s payment call."
}

main 2>&1 | tee "$root/evidence/01_lost_update.txt"
