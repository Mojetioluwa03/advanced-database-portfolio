# Portfolio 3 — Transactions and Concurrency

**Marks:** 7 of 40
**Status:** not started

## Scope

Demonstrating ACID behaviour and concurrency control against the ShopStack schema,
using the inventory ledger as the main vehicle because it is where real contention
occurs.

Planned scenarios, each with captured output:

1. **Commit and rollback** — placing an order as a single unit of work: insert the
   order, its lines, decrement `stock_level`, append `stock_movement` rows. Roll back
   halfway and show that neither stock nor ledger changed.
2. **Atomicity proof** — an intentionally failing statement mid-transaction (for
   example a line total that violates its check constraint) and the resulting clean
   state.
3. **Lost update** — two concurrent sessions selling the last unit of the same
   variant. Show the anomaly with `READ COMMITTED`, then the fix with
   `SELECT ... FOR UPDATE` or an atomic conditional `UPDATE ... WHERE quantity >= n`.
4. **Non-repeatable read and phantom read** — the same read twice inside one
   transaction at `READ COMMITTED`, then at `REPEATABLE READ`, with the difference
   visible.
5. **Deadlock** — two transactions acquiring the same two stock rows in opposite
   order; capture PostgreSQL's deadlock detection and abort message.
6. **Isolation level comparison** — a table of which anomalies each level prevents.

## Planned files

```
transactions.sql       DDL-free scenario scripts, runnable from two psql sessions
scenarios/*.md         one write-up per scenario: setup, commands, output, explanation
output/*.txt           captured psql transcripts
README.md              results table and analysis
```
