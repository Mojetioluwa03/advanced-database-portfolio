#!/usr/bin/env bash
# Run the single-session demonstrations and capture each transcript.
#
#   ./run_transactions.sh                 # portable cluster on 5433 (default)
#   PGPORT=5432 ./run_transactions.sh     # a server of your own
#
# Evidence lands in evidence/, one file per script, with the command line at the
# top so each transcript stands on its own.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

PSQL=${PSQL_BIN:-../../.pg16/pgsql/bin/psql}
PGHOST=${PGHOST:-localhost}
PGPORT=${PGPORT:-5433}
PGUSER=${PGUSER:-postgres}
PGDATABASE=${PGDATABASE:-shopstack}
export PGHOST PGPORT PGUSER PGDATABASE

mkdir -p evidence

run() {
    local script=$1 out="evidence/$(basename "${1%.sql}").txt"
    echo "==> $script"
    {
        echo "\$ psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f $script"
        echo
        status=0
        "$PSQL" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -f "$script" 2>&1 \
            || status=$?
        echo
        echo "--- psql exit status: $status ---"
    } > "$out"
}

for script in transactions/0*.sql; do
    run "$script"
done

echo "transcripts written to evidence/"
