#!/usr/bin/env bash
# =============================================================================
#  Portfolio 4 - rebuild the document store and capture every number.
#
#      bash run_queries.sh
#
#  Sequence:
#    1. load 10,000 products from the Portfolio 1 CSV into MongoDB
#    2. capture the unindexed baseline           -> plans/before/
#    3. build the three indexes                  -> results/index_build.txt
#    4. capture the indexed run                  -> plans/after/
#    5. capture the relational equivalents       -> plans/sql/, results/sql/
#    6. run the $elemMatch experiment            -> results/
#
#  The document store is dropped and reloaded first, so the baseline really is
#  unindexed. Re-running the whole script is safe and idempotent.
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

mongosh_bin="${MONGOSH_BIN:-}"
if [ -z "$mongosh_bin" ] && [ -x "../../.mongo/bin/mongosh.exe" ]; then
    mongosh_bin="../../.mongo/bin/mongosh.exe"
fi
mongosh_bin="${mongosh_bin:-mongosh}"

uri="${MONGO_URI:-mongodb://127.0.0.1:27018/shopstack?directConnection=true}"

mkdir -p plans results

if ! "$mongosh_bin" "$uri" --quiet --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1; then
    cat >&2 <<'MSG'
mongod is not answering on the expected port.

Start the portable server first (from the workspace root):

  powershell -NoProfile -Command "Start-Process -FilePath '.mongo\bin\mongod.exe' \
    -ArgumentList '--dbpath','.mongodata','--port','27018','--bind_ip','127.0.0.1', \
    '--logpath','.mongodata\mongod.log','--logappend' -WindowStyle Hidden"

Or point MONGO_URI at another server.
MSG
    exit 1
fi

echo "############ 1. load ############"
"${PYTHON:-python}" load_catalogue.py | tee results/load.txt
echo

echo "############ 2. baseline, unindexed ############"
bash capture_mql.sh before
echo

echo "############ 3. indexes ############"
"$mongosh_bin" "$uri" --quiet --file model/indexes.js | tee results/index_build.txt
echo

echo "############ 4. indexed ############"
bash capture_mql.sh after
echo

echo "############ 5. relational equivalents ############"
bash capture_sql.sh
echo

echo "############ 6. experiments ############"
for f in experiments/*.js; do
    name="$(basename "$f" .js)"
    {
        echo "\$ mongosh \$MONGO_URI --quiet --file $f"
        "$mongosh_bin" "$uri" --quiet --file "$f"
    } > "results/experiment-$name.txt" 2>&1 || {
        echo "FAILED: $f" >&2
        cat "results/experiment-$name.txt" >&2
        exit 1
    }
    echo "  $name -> results/experiment-$name.txt"
done
echo

echo "done: plans/{before,after,sql}, results/*.csv"
