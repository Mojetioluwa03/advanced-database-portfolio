#!/usr/bin/env bash
# 02 — what an isolation level actually buys you.
#
# The observer script runs twice: once at READ COMMITTED, once at REPEATABLE
# READ. In both runs a writer session restocks the row and appends a ledger
# entry while the observer is inside its transaction.
#
#   READ COMMITTED  - each statement takes a new snapshot: the observer sees 1,
#                     then 5, then 5, and its movement count goes 0 -> 1.
#   REPEATABLE READ - the whole transaction keeps the snapshot taken at its first
#                     statement: the observer sees 1, 1, 1 and 0, 0, 0 even though
#                     the writer committed at ~690 ms.
#   READ UNCOMMITTED - a third phase asks for the level that permits dirty reads;
#                     a writer leaves 999 uncommitted for 3 s and the reader sees
#                     1 anyway, because PostgreSQL has no dirty reads.
#
# SERIALIZABLE is not shown here because its distinctive failure (40001 on a
# write-skew pattern) needs a different shape of race; see 04_serializable.sh.
#
#   ./02_isolation_levels.sh               # portable cluster on 5433
#
# Writes the whole transcript to ../evidence/02_isolation_levels.txt.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$root/evidence"

phase() {
    local level=$1
    reset_fixture
    set_stock 1
    echo "starting state: 1 unit on hand, empty ledger"
    show_state
    echo
    run_sessions isolation_observer.sql isolation_writer.sql -v iso="$level"
    echo
    echo "=== committed state after the writer ==="
    show_state
    echo
}

main() {
    echo "\$ concurrency/02_isolation_levels.sh"
    echo "PostgreSQL $("$PSQL" --version | awk '{print $3}'), $PGHOST:$PGPORT/$PGDATABASE"
    echo

    echo "############ PHASE 1 - READ COMMITTED ############"
    phase "read committed"
    echo "Each statement saw the newest committed data: B's committed restock"
    echo "appeared in the middle of A's transaction. That is a non-repeatable"
    echo "read (the row changed) plus a phantom (the count gained a row)."
    echo

    echo "############ PHASE 2 - REPEATABLE READ ############"
    phase "repeatable read"
    echo "The same two statements returned the same two answers all three times:"
    echo "the transaction read from one snapshot taken at its first statement, so"
    echo "the writer's commit, under a second into A's transaction, was invisible"
    echo "to it. Nothing was blocked; the cost is that A could commit a decision"
    echo "based on data that is 3s old."
    echo

    echo "############ PHASE 3 - READ UNCOMMITTED (a dirty read that never happens) ############"
    reset_fixture
    set_stock 1
    echo "starting state: 1 unit on hand"
    show_state
    echo
    run_sessions dirty_reader.sql dirty_writer.sql -v iso="read uncommitted"
    echo
    echo "=== committed state after the rollback ==="
    show_state
    echo
    echo "B held 999 uncommitted for 3s. A asked for READ UNCOMMITTED - the level"
    echo "that exists precisely to permit dirty reads - and still read 1, because"
    echo "PostgreSQL has no dirty reads at any level: readers see the last"
    echo "committed version and never block on the writer. SHOW echoes the level"
    echo "back, but the behaviour is READ COMMITTED's."
}

main 2>&1 | tee "$root/evidence/02_isolation_levels.txt"
