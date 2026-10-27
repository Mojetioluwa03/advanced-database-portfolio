#!/usr/bin/env bash
# Run the four two-session demonstrations. Each one resets the fixture itself,
# prints its transcript and writes it to evidence/; this runner only sequences
# them and reports progress.
#
#   ./run_concurrency.sh                    # portable cluster on 5433
#   PGPORT=5432 ./run_concurrency.sh        # a server of your own

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

for demo in "$here"/concurrency/0*.sh; do
    echo "==> concurrency/$(basename "$demo")"
    bash "$demo" > /dev/null
done

echo "transcripts written to evidence/"
