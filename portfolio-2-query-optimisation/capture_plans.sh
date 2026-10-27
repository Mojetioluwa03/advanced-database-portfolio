#!/usr/bin/env bash
# =============================================================================
#  Capture EXPLAIN (ANALYZE, BUFFERS) plans and timings for every query.
#
#      ./capture_plans.sh before     # unindexed schema
#      psql -d shopstack -f indexes.sql
#      ./capture_plans.sh after      # same queries, same data
#
#  Method
#    1. VACUUM (ANALYZE) so statistics and the visibility map are current.
#    2. One discarded warm-up run of every query, so both phases are measured
#       with a hot cache. Without this the "after" phase would look faster
#       simply because building the indexes had read every table into memory.
#    3. Three measured runs per query. All three are kept in the plan file; the
#       median goes into the CSV so one slow run cannot skew the comparison.
#
#  Parallel query and JIT are switched off for the measurement. Parallel workers
#  report buffer counts per worker, which makes "buffers" incomparable, and JIT
#  adds a fixed start-up cost on a laptop. The server's real defaults are noted
#  in the README.
#
#  Connection defaults target the portable cluster described in ../README.md;
#  override with PGHOST/PGPORT/PGUSER/PGDATABASE, or set PSQL_BIN.
# =============================================================================
set -euo pipefail

phase="${1:-}"
case "$phase" in
    before|after) ;;
    *) echo "usage: $0 before|after" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")"

# Prefer an explicit PSQL_BIN, then the portable cluster used to build this
# portfolio (../.pg16), then whatever psql is on PATH.
psql_bin="${PSQL_BIN:-}"
if [ -z "$psql_bin" ] && [ -x "../../.pg16/pgsql/bin/psql" ]; then
    psql_bin="../../.pg16/pgsql/bin/psql"
fi
psql_bin="${psql_bin:-psql}"

PSQL=("$psql_bin" -X -q -v ON_ERROR_STOP=1
      -h "${PGHOST:-localhost}" -p "${PGPORT:-5433}"
      -U "${PGUSER:-postgres}" -d "${PGDATABASE:-shopstack}")

# Emit a psql script of <runs> EXPLAIN blocks for one query file.
explain_script() {
    local qfile="$1" runs="$2"
    echo "SET max_parallel_workers_per_gather = 0;"
    echo "SET jit = off;"
    local run
    for ((run = 1; run <= runs; run++)); do
        echo "\\echo '===== run $run ====='"
        echo "EXPLAIN (ANALYZE, BUFFERS)"
        grep -v '^[[:space:]]*--' "$qfile"
    done
}

mkdir -p "plans/$phase" results
csv="results/timings.csv"
if [ "$phase" = before ]; then
    echo "phase,query,run1_ms,run2_ms,run3_ms,median_ms,rows,shared_hit,shared_read,shared_pages" > "$csv"
fi

echo "VACUUM (ANALYZE) ..."
echo "VACUUM (ANALYZE);" | "${PSQL[@]}" -f - >/dev/null

echo "warm-up pass (discarded) ..."
for f in queries/q*.sql; do
    name="$(basename "$f" .sql)"
    printf '  %s ' "$name"
    explain_script "$f" 1 > "plans/$phase/.warmup.sql"
    "${PSQL[@]}" -f "plans/$phase/.warmup.sql" >/dev/null
    echo ok
done
rm -f "plans/$phase/.warmup.sql"

echo
printf '%-34s %10s %10s %12s\n' query median_ms rows buffers

for f in queries/q*.sql; do
    name="$(basename "$f" .sql)"
    out="plans/$phase/$name.txt"

    explain_script "$f" 3 > "${out}.tmp"
    "${PSQL[@]}" -f "${out}.tmp" > "$out"
    rm -f "${out}.tmp"

    times=$(grep -o 'Execution Time: [0-9.]*' "$out" | awk '{print $3}' | paste -sd' ' -)
    r1=$(printf '%s' "$times" | cut -d' ' -f1)
    r2=$(printf '%s' "$times" | cut -d' ' -f2)
    r3=$(printf '%s' "$times" | cut -d' ' -f3)
    median=$(printf '%s\n' "$r1" "$r2" "$r3" | sort -g | sed -n 2p)

    rows=$(grep -m1 'actual time=' "$out" | grep -o 'rows=[0-9]*' | tail -1 | cut -d= -f2 || true)
    # The top node's buffer line looks like
    #   Buffers: shared hit=123 read=45, temp read=678 written=679
    # so temp I/O is stripped out before the shared read count is taken.
    buf=$(grep -m1 'Buffers:' "$out" || true)
    hit=$(printf '%s\n' "$buf" | grep -o 'shared hit=[0-9]*' | head -1 | cut -d= -f2 || true)
    read=$(printf '%s\n' "$buf" | sed 's/temp read=[0-9]* written=[0-9]*//' \
           | grep -o 'read=[0-9]*' | head -1 | cut -d= -f2 || true)
    hit=${hit:-0}; read=${read:-0}
    pages=$(( hit + read ))

    echo "$phase,$name,$r1,$r2,$r3,$median,$rows,$hit,$read,$pages" >> "$csv"
    printf '%-34s %10s %10s %12s\n' "$name" "$median" "$rows" "${pages}(${hit}+${read})"
done

echo
echo "plans   -> plans/$phase/"
echo "timings -> $csv"
