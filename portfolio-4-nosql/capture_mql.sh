#!/usr/bin/env bash
# =============================================================================
#  Capture plan stats and results for the five MQL queries.
#
#      ./capture_mql.sh before      # unindexed baseline
#      mongosh ... --file model/indexes.js
#      ./capture_mql.sh after       # same queries, same data
#
#  Each query file runs its own reportPlan() (one discarded run, three measured
#  runs, median) and then fetches its results. The transcript in plans/<phase>/
#  therefore shows the plan and the output of the same query object.
#
#  executionTimeMillis is measured server-side inside an explain(), so mongosh
#  start-up and the wire are outside the number.
# =============================================================================
set -euo pipefail

phase="${1:-}"
case "$phase" in
    before|after) ;;
    *) echo "usage: $0 before|after" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")"

# Prefer an explicit MONGOSH_BIN, then the portable shell used to build this
# portfolio (../../.mongo/bin), then whatever mongosh is on PATH.
mongosh_bin="${MONGOSH_BIN:-}"
if [ -z "$mongosh_bin" ] && [ -x "../../.mongo/bin/mongosh.exe" ]; then
    mongosh_bin="../../.mongo/bin/mongosh.exe"
fi
mongosh_bin="${mongosh_bin:-mongosh}"

uri="${MONGO_URI:-mongodb://127.0.0.1:27018/shopstack?directConnection=true}"

mkdir -p "plans/$phase" results
csv="results/mql_timings.csv"
if [ "$phase" = before ]; then
    echo "phase,query,plan,keysExamined,docsExamined,cursorReturned,returned,median_ms" > "$csv"
fi

printf '%-26s %-44s %7s %7s %6s %8s\n' query plan keys docs rows median_ms

for f in queries/q[0-9]*.js; do
    name="$(basename "$f" .js)"
    out="plans/$phase/$name.txt"

    {
        echo "\$ mongosh \$MONGO_URI --quiet --file $f"
        "$mongosh_bin" "$uri" --quiet --file "$f"
    } > "$out" 2>&1 || {
        echo "FAILED: $f" >&2
        cat "$out" >&2
        exit 1
    }

    plan=$(grep -m1 '^    plan ' "$out" | sed 's/^    plan *//')
    keys=$(grep -m1 '^    keysExamined ' "$out" | awk '{print $2}')
    docs=$(grep -m1 '^    docsExamined ' "$out" | awk '{print $2}')
    cursor=$(grep -m1 '^    cursorReturned ' "$out" | awk '{print $2}')
    rows=$(grep -m1 '^    returned ' "$out" | awk '{print $2}')
    ms=$(grep -m1 '^    execMs ' "$out" | sed 's/.*median //')

    echo "$phase,$name,\"$plan\",$keys,$docs,$cursor,$rows,$ms" >> "$csv"
    printf '%-26s %-44s %7s %7s %6s %8s\n' "$name" "$plan" "$keys" "$docs" "$rows" "$ms"
done

echo
echo "transcripts -> plans/$phase/"
echo "timings     -> $csv"
