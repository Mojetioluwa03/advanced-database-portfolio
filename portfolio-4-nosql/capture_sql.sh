#!/usr/bin/env bash
# =============================================================================
#  Capture EXPLAIN (ANALYZE, BUFFERS) plans, timings and row counts for the
#  relational half of each query pair.
#
#      ./capture_sql.sh
#
#  Method mirrors Portfolio 2's capture_plans.sh so the two portfolios are
#  measured the same way: VACUUM (ANALYZE), one discarded warm-up run, three
#  measured runs, median into a CSV. Parallel query and JIT are off so the
#  buffer and timing numbers stay comparable run to run.
#
#  The relational side is measured once, against the schema as Portfolio 2 left
#  it - that is, with its indexes in place. Only the document store has a
#  before/after comparison, because only it starts from zero.
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

psql_bin="${PSQL_BIN:-}"
if [ -z "$psql_bin" ] && [ -x "../../.pg16/pgsql/bin/psql" ]; then
    psql_bin="../../.pg16/pgsql/bin/psql"
fi
psql_bin="${psql_bin:-psql}"

PSQL=("$psql_bin" -X -q -v ON_ERROR_STOP=1
      -h "${PGHOST:-localhost}" -p "${PGPORT:-5433}"
      -U "${PGUSER:-postgres}" -d "${PGDATABASE:-shopstack}")

mkdir -p plans/sql results/sql
csv="results/sql_timings.csv"
echo "query,run1_ms,run2_ms,run3_ms,median_ms,rows,shared_pages" > "$csv"

# Query bodies without comment lines and without the trailing semicolon, so a
# statement can be wrapped in a subquery when only its row count is wanted.
strip() { grep -v '^[[:space:]]*--' "$1" | sed 's/;[[:space:]]*$//'; }

explain_script() {
    local qfile="$1" runs="$2" run
    echo "SET max_parallel_workers_per_gather = 0;"
    echo "SET jit = off;"
    for ((run = 1; run <= runs; run++)); do
        echo "\\echo '===== run $run ====='"
        echo "EXPLAIN (ANALYZE, BUFFERS)"
        strip "$qfile"
        echo ";"
    done
}

echo "VACUUM (ANALYZE) ..."
echo "VACUUM (ANALYZE);" | "${PSQL[@]}" -f - >/dev/null

echo "warm-up pass (discarded) ..."
for f in queries/sql/q*.sql; do
    explain_script "$f" 1 > "plans/sql/.warmup.sql"
    "${PSQL[@]}" -f "plans/sql/.warmup.sql" >/dev/null
    echo "  $(basename "$f") ok"
done
rm -f plans/sql/.warmup.sql

echo
printf '%-28s %10s %8s %12s\n' query median_ms rows buffers

for f in queries/sql/q*.sql; do
    name="$(basename "$f" .sql)"
    out="plans/sql/$name.txt"

    explain_script "$f" 3 > "${out}.tmp"
    "${PSQL[@]}" -f "${out}.tmp" > "$out"
    rm -f "${out}.tmp"

    times=$(grep -o 'Execution Time: [0-9.]*' "$out" | awk '{print $3}' | paste -sd' ' -)
    r1=$(printf '%s' "$times" | cut -d' ' -f1)
    r2=$(printf '%s' "$times" | cut -d' ' -f2)
    r3=$(printf '%s' "$times" | cut -d' ' -f3)
    median=$(printf '%s\n' "$r1" "$r2" "$r3" | sort -g | sed -n 2p)

    # Row count and a three-row peek, both through the same query body.
    count_sql="SELECT count(*) FROM (
$(strip "$f")
) s;"
    rows=$(printf '%s\n' "$count_sql" | "${PSQL[@]}" -t -A -f -)

    {
        echo "\\pset pager off"
        echo "\\echo '===== first 3 rows ====='"
        echo "\\x on"
        echo "SELECT * FROM ("
        strip "$f"
        echo ") s LIMIT 3;"
    } > "${out}.rows.sql"
    "${PSQL[@]}" -f "${out}.rows.sql" > "results/sql/$name.txt" 2>&1
    rm -f "${out}.rows.sql"

    pages=$(grep -m1 'Buffers:' "$out" | grep -o 'shared hit=[0-9]*' | head -1 | cut -d= -f2 || true)
    pages=${pages:-0}

    echo "$name,$r1,$r2,$r3,$median,${rows:-0},$pages" >> "$csv"
    printf '%-28s %10s %8s %12s\n' "$name" "$median" "${rows:-0}" "$pages"
done

echo
echo "plans  -> plans/sql/"
echo "rows   -> results/sql/"
echo "timings-> $csv"
