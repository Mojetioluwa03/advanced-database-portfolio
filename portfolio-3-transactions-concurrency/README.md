# Portfolio 3 — Transactions and Concurrency

**Marks:** 7 of 40
**Status:** complete — three single-session transaction demos, four two-session
races, transcripts captured
**Case study:** ShopStack (see the root README for the full case study statement)

---

## 1. What this activity delivers

The graded requirements — COMMIT, ROLLBACK, isolation levels, and a concurrency
problem with its control mechanism — map onto the files as follows.

| Requirement | Demonstrated by | Evidence |
|---|---|---|
| COMMIT, atomic multi-statement work | `transactions/01_checkout_commit.sql` | `evidence/01_checkout_commit.txt` |
| ROLLBACK, and the aborted-transaction state | `transactions/02_checkout_rollback.sql` | `evidence/02_checkout_rollback.txt` |
| Partial rollback | `transactions/03_savepoint_partial_failure.sql` | `evidence/03_savepoint_partial_failure.txt` |
| Lost update / oversell, and two fixes | `concurrency/01_lost_update.sh` | `evidence/01_lost_update.txt` |
| READ COMMITTED vs REPEATABLE READ, no dirty read | `concurrency/02_isolation_levels.sh` | `evidence/02_isolation_levels.txt` |
| Deadlock detection and resolution | `concurrency/03_deadlock.sh` | `evidence/03_deadlock.txt` |
| Write skew, SERIALIZABLE, retry | `concurrency/04_serializable.sh` | `evidence/04_serializable.txt` |

Supporting files:

| File | Purpose |
|---|---|
| `setup_test_data.sql` | Idempotent fixture: one brand, product, variant, two warehouses, one customer |
| `run_transactions.sh` | Runs the three single-session scripts into `evidence/` |
| `run_concurrency.sh` | Runs the four two-session demos into `evidence/` |
| `concurrency/lib.sh` | Connection settings, fixture reset, state queries, two-session runner |
| `concurrency/sessions/*.sql` | The SQL each psql session runs in the races |
| `evidence/*.txt` | Captured psql transcripts, command line at the top of each |

Every transcript in `evidence/` is raw psql output: nothing was retyped or
trimmed. Timings quoted below are from the committed transcripts; they move by
tens of milliseconds between runs and machines, which is why every race is built
around 1.5–2.4 s sleeps rather than millisecond timing.

The fixture is deliberately separate from the 1.35M seeded rows. It is addressed
by literal SKU and email, never by id, so each demo can reset itself and the
identity sequences can be anywhere.

---

## 2. What a business transaction is here

The unit of work used throughout is a checkout: create the order, price the
line, take the units out of stock, write the ledger entry, take the payment and
mark the order paid. Six statements, five tables, one business fact. If any one
of them fails, the correct outcome is that none of them happened — an order that
was paid but never reserved stock, or stock that left the warehouse for an order
that does not exist, is exactly the kind of inconsistency the ledger is meant to
prevent.

`stock_movement` is the table that makes this measurable. It is append-only in
practice, and `ck_movement_sale_ref` requires every `'sale'` row to point at an
order. So the ledger can be compared with `stock_level` after every demo: if the
two disagree, a transaction was not atomic.

---

## 3. Single session: COMMIT, ROLLBACK, SAVEPOINT

### 3.1 COMMIT — all six statements or none

`01_checkout_commit.sql` runs the six statements, then asks the same three
questions before and after `COMMIT`. Before the commit the session sees its own
writes, which is expected: uncommitted data is visible to its own transaction
only. After the commit the stock is 10 → 8, the order is `paid`, the line is 2 ×
25.00, the payment is 50.00 and one `'sale'` movement of −2 points back at the
order.

One detail matters more than it looks: the stock update is

```sql
UPDATE stock_level
   SET quantity = quantity - 2, updated_at = now()
 WHERE ... AND quantity >= 2;
```

The availability check is part of the statement, not a separate `SELECT` before
it. That is the same idea as the guarded update in §5.3, applied to a
single-session case; it costs nothing and removes a race that would otherwise
exist between the check and the write.

### 3.2 ROLLBACK — a failed payment leg

`02_checkout_rollback.sql` runs four of the six statements successfully, then
tries to insert a payment of −50.00. `ck_payment_amount CHECK (amount > 0)`
rejects it:

```
ERROR:  new row for relation "payment" violates check constraint "ck_payment_amount"
DETAIL:  Failing row contains (181523, 200009, stripe, card, -50.00, paid, ...)
```

A deliberately placed `SELECT` afterwards shows what a careless application would
hit next:

```
ERROR:  current transaction is aborted, commands ignored until end of transaction block
```

That is SQLSTATE 25P02, and it is not an error the application can recover from
inside the transaction. It is the database refusing to run further statements
against a transaction it has already decided cannot commit. The only options are
`ROLLBACK` (or `ROLLBACK TO SAVEPOINT`, §3.3). After the rollback the transcript
re-queries everything the checkout wrote: stock back at 10, zero orders, zero
sale movements, zero payments.

Worth noting: the check constraint, not the application, caught this. That is the
right division of labour. Constraints are the last line of defence, and they run
whether or not the code that called them remembered to validate.

### 3.3 SAVEPOINT — keeping the reservation, discarding the charge

A declined card should not throw away the stock reservation; it should fail the
payment leg and leave the order pending for a retry. `03_savepoint_partial_failure.sql`
places `SAVEPOINT before_payment` after the order, line and stock reservation,
lets the same negative payment fail, then:

```
ROLLBACK TO SAVEPOINT before_payment
```

and inserts a `'failed'` payment row instead, before committing. Final state: the
order exists and is `pending`, stock is 8, the ledger has one −2 sale movement,
and the only payment row says `failed`. The savepoint turned one all-or-nothing
transaction into two units of work with an explicit boundary.

`ROLLBACK TO SAVEPOINT` does not end the transaction. A later `COMMIT` still
commits everything before the savepoint, which is why this demo needs a `COMMIT`
after the rollback while §3.2 ends with `ROLLBACK`.

---

## 4. How the two-session races are orchestrated

`concurrency/lib.sh` starts each session as its own `psql` process against the
same database, session B 0.4 s after session A. Every output line is prefixed
with its offset in milliseconds from the start of the race, so the transcripts
show what actually overlapped rather than two logs stapled together. The stamp
uses bash's `EPOCHREALTIME`, not a `date` call per line: a per-line process would
add ~30 ms of artificial skew on this machine and could make a later line look
like it happened before an earlier one.

Two consequences of using real processes are visible in the evidence and worth
stating:

- Which session wins a race is deterministic only because the script spaces the
  sleeps; where the database is free to choose (the deadlock victim) the README
  says so.
- A session that hits an error exits with psql status 3 because it runs with
  `ON_ERROR_STOP`. For the victim of a deadlock or a serialization failure that
  is the expected outcome, not a script failure.

The alternative would have been psql's `\parallel`, which opens several
connections from one client. Separate processes were chosen because each
transcript then stands alone, and the exit status of each session can be checked
independently.

---

## 5. Lost update: the oversell, and two fixes

### 5.1 The bug

Phase 1 of `01_lost_update.sh` starts with **one unit** on hand and runs the
naive application pattern in both sessions:

1. read `quantity` into the application,
2. validate the payment (a 2 s sleep),
3. write back "what I read, minus one".

A reads 1 at 157 ms and sleeps. B starts at 400 ms, reads **1** at 624 ms —
A has not committed, so at READ COMMITTED B sees the last committed value — and
sleeps. A commits 0 at 2,179 ms. B commits 0 at 3,035 ms. Committed outcome:

```
 on_hand | orders | sale_movements | units_sold
---------+--------+----------------+------------
       0 |      2 |              2 |         -2
```

Two paid orders, two −1 sale movements, and one unit ever existed. The ledger
claims two units left the warehouse while the total fell by one.

The most interesting part is what did **not** happen: no constraint fired.
`ck_stock_quantity CHECK (quantity >= 0)` never saw a negative number, because
neither session asked the database to do arithmetic. Both computed `1 - 1` in the
application and wrote `0`. The constraint protects against a wrong value being
written, not against a decision made on stale data.

### 5.2 Fix 1 — `SELECT ... FOR UPDATE`

Phase 2 takes a row lock before deciding. A locks the row at 161 ms and holds it
across the payment call. B's `FOR UPDATE` blocks at 659 ms and returns at
2,169 ms — after A commits — reading **0**, not 1:

```
[ 2169 ms] [B] unblocked; on-hand is now 0
[ 2170 ms] [B] not enough stock: refusing the sale and rolling back
```

B rolls back, and the query for its own order returns 0 rows. Final state: one
order, one movement, stock 0. The lock makes the decision use committed data, and
it is the only fix here that also protects a decision that takes several
statements to implement.

The cost is real: the lock is held for the 2 s payment call, so every other
checkout of that SKU waits. Fix 2 removes that.

### 5.3 Fix 2 — a guarded `UPDATE`

Phase 3 never reads the stock to decide anything. Each session runs

```sql
UPDATE stock_level
   SET quantity = quantity - 1
 WHERE ... AND quantity >= 1;
```

and asks how many rows changed. A's guard matches at 2,180 ms; B's matches no row
at 2,694 ms and its checkout rolls back:

```
[ 2694 ms] [B] the guard matched no row: refusing the sale and rolling back
```

The database evaluates `quantity >= 1` against the row version it is about to
write, while holding the write lock for that statement only. No lock is held
across the payment call, no stale value is ever subtracted, and the row count is
the answer to "did I sell it?". The transaction is wrapped in a CTE so the count
can be captured as a boolean — psql's `\gset` refuses a query that returns no
rows, and "the guard matched nothing" is exactly the case that must be handled.

This is the pattern used in production for single-row reservations, and it is
what §3.1 already does. `FOR UPDATE` is still the right tool when the decision
spans multiple statements or multiple rows.

### 5.4 The three phases side by side

| | Naive read-modify-write | `FOR UPDATE` | Guarded `UPDATE` |
|---|---|---|---|
| Orders committed from 1 unit | 2 | 1 | 1 |
| Final on-hand | 0 | 0 | 0 |
| Ledger vs stock | −2 vs −1, inconsistent | consistent | consistent |
| Lock held during payment call | no | yes, 2 s | no |
| Blocking victim | none | B waits 1.5 s | none |
| Extra round trip | read + write | read + write | one statement |

---

## 6. Isolation levels: what the transaction sees

`02_isolation_levels.sh` runs one observer script twice. The observer asks the
same two questions three times inside one transaction; a writer restocks 4 units
and appends a ledger row at ~690 ms. The two questions have different shapes on
purpose: `on_hand` is a value that changes, and the movement count is a set that
gains a row.

| Read (offset) | READ COMMITTED | REPEATABLE READ |
|---|---|---|
| 1 — before B commits (~130 ms) | 1 unit, 0 movements | 1 unit, 0 movements |
| 2 — after B commits (~2,170 ms) | **5 units, 1 movement** | 1 unit, 0 movements |
| 3 — 1 s later (~3,240 ms) | 5 units, 1 movement | 1 unit, 0 movements |

At READ COMMITTED each statement gets a fresh snapshot, so the observer sees the
row change (a non-repeatable read) and the set grow (a phantom read) without
leaving its transaction. At REPEATABLE READ the whole transaction reads from the
snapshot taken at its first statement, so B's commit is invisible to it for the
rest of its life. Nothing was blocked in either case; the difference is what the
observer was allowed to see.

The writer's own uncommitted view is 5 units and 1 movement in both runs — an
uncommitted transaction always sees its own writes, whatever the level.

PostgreSQL has no dirty reads even when asked for them. Phase 3 starts a writer
that sets on-hand to 999 and leaves it uncommitted for 3 s, and a reader whose
transaction was opened with READ UNCOMMITTED. `SHOW transaction_isolation` echoes
`read uncommitted` back, and the read still returns 1 at 1,361 ms — the last
committed version — without blocking on the writer. The level is accepted as an
alias for READ COMMITTED and there is no code path that returns a dirty row. That
row of a textbook table therefore cannot be demonstrated on this server; only the
absence of the anomaly can be.

REPEATABLE READ here is also stronger than the SQL standard requires:
PostgreSQL's implementation is snapshot isolation, which prevents phantoms as
well as non-repeatable reads. §7 is what it still does not prevent.

---

## 7. Write skew: the anomaly snapshots cannot see

`04_serializable.sh` enforces a rule that spans rows: at least one unit of the
variant must remain across the two warehouses, so a sale is allowed only when the
combined total is ≥ 2. Each session checks the total, then takes one unit out of
a **different** warehouse.

Under REPEATABLE READ both sessions read a total of 2, both sleep 1.5 s, both
write their own row and both commit. Final total: **0**. Neither lost an update —
no row was written twice — and neither was blocked. The rule was broken because
each transaction validated against a total the other changed, and snapshot
isolation cannot express a constraint that spans two rows written by two
transactions. This is write skew.

Under SERIALIZABLE the same two scripts produce a different outcome. Session A
commits at 1,684 ms; session B fails at 2,165 ms:

```
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
HINT:  The transaction might succeed if retried.
```

One unit sold, one remains. The cost is that the losing transaction must be
retried: `04_serializable.sh` re-runs B's script, which reads a total of 1,
refuses the sale and rolls back. That retry is the caller's job — SERIALIZABLE
guarantees a serializable outcome, not that every attempt commits.

### 7.1 Which level prevents what

"Observed" means the anomaly is reproduced in `evidence/`; "prevented" means the
observed run under that level did not produce it.

| Anomaly | READ COMMITTED | REPEATABLE READ | SERIALIZABLE |
|---|---|---|---|
| Dirty read | impossible, even at READ UNCOMMITTED (§6) | impossible | impossible |
| Non-repeatable read | observed (§6) | prevented (§6) | prevented |
| Phantom read | observed (§6) | prevented (§6) | prevented |
| Lost update (read-modify-write) | observed (§5.1) | prevented by 40001 | prevented by 40001 |
| Write skew | possible | observed (§7) | prevented by 40001 (§7) |
| Deadlock | possible (§8) | possible | possible |

Deadlock is not an isolation problem, which is why no level prevents it: it is
lock acquisition order, and the fix is to acquire in a consistent order or to
retry. The default `deadlock_timeout` of 1 s means a deadlock costs a second of
waiting before the detector fires, which is why it is worth preventing rather
than detecting.

For this schema the practical reading is: READ COMMITTED plus guarded updates
covers single-row contention; use SERIALIZABLE only for decisions that span rows
and must hold as an invariant, and pay for it with a retry loop.

---

## 8. Deadlock: lock ordering, not isolation

`03_deadlock.sh` gives both warehouses one unit. A locks warehouse 1 then asks
for warehouse 2; B locks warehouse 2 then asks for warehouse 1, 0.4 s later.
Each holds what the other needs, so at ~3,173 ms PostgreSQL aborts one of them:

```
ERROR:  deadlock detected
DETAIL:  Process 21076 waits for ShareLock on transaction 1408; blocked by process 4312.
         Process 4312 waits for ShareLock on transaction 1407; blocked by process 21076.
HINT:  See server log for query details.
```

The survivor's blocked `UPDATE` then proceeds and commits. On-hand is 0 in both
warehouses, and the ledger holds exactly two rows totalling −2 — the survivor's.
The victim's first update and its first ledger row were rolled back, so the cycle
cost one transaction, not one unit, and nothing was counted twice.

Two honest caveats. Which session is the victim is not deterministic; in the
committed transcript A is aborted and B commits, but the script does not rely on
it, and the final state is the same either way. And this demo writes its ledger
rows with reason `'adjustment'` because it is about lock ordering, not order
flow; using `'sale'` would require creating an order in each session for no extra
insight.

The fix in application code is to acquire locks in a consistent order — always by
ascending `warehouse_id` — or to make each session take all its locks in one
statement. The demo shows what happens when that discipline is absent.

---

## 9. A schema finding from building the fixture

Running the demos repeatedly needs a teardown, and the teardown found something
about the schema rather than about transactions.

`stock_movement.ref_order_id` is `ON DELETE SET NULL`, but
`ck_movement_sale_ref CHECK (reason <> 'sale' OR ref_order_id IS NOT NULL)` says a
sale row must have an order. Deleting an order therefore sets its sale movements'
`ref_order_id` to NULL, which the check rejects:

```
new row for relation "stock_movement" violates check constraint "ck_movement_sale_ref"
```

So an order with sale movements can never be deleted — the ledger is effectively
immutable. That is arguably the right behaviour for a ledger, but it is enforced
by an error message that does not explain it, and the `ON DELETE SET NULL` clause
advertises a capability the constraint forbids. `setup_test_data.sql` deletes the
test variant's movements before the orders, and the fixture comment records why.

The reversible alternative is one line in `schema.sql`:

```sql
ref_order_id INTEGER REFERENCES customer_order (order_id) ON DELETE RESTRICT
```

which fails at the delete with "violates foreign key constraint" instead of
silently attempting a NULL. It is not one line in a live database — the
constraint has to be dropped and recreated under a new name — so it is recorded
here as a schema change to make deliberately in Portfolio 4's reworking rather
than patched mid-portfolio. The current behaviour is safe; it is only the error
message that is misleading.

---

## 10. Limitations and what I would do next

- **Two sessions, not a crowd.** Every race is hand-orchestrated with sleeps, so
  the timing windows are generous and the transcripts are readable. They do not
  measure throughput or contention at 50 concurrent checkouts; a benchmark client
  (pgbench with a custom script) would.
- **No retry policy.** `04_serializable.sh` retries once, manually, because the
  point is that a retry is required. A production caller needs bounded retries
  with backoff on SQLSTATE 40001 and 40P01, and idempotency so a retried checkout
  cannot create two orders.
- **Row-level contention only.** The demonstrations use the two test warehouses
  and one SKU. The seeded dataset has 26 tables and 1.35M rows; nothing here
  characterises lock behaviour on the large order tables.
- **The isolation table is scoped to the anomalies tested.** It is not a proof
  that SERIALIZABLE prevents every anomaly; it shows that the specific patterns
  in §5–§8 behave as the documentation says.
- **`ck_movement_sale_ref`** is not changed in this portfolio (§9). If it is
  changed, this README and the fixture comment need to change with it.

---

## 11. Reproducing

The portfolio was run against a portable PostgreSQL 16.15 cluster on port 5433
with database `shopstack`; the root README explains how that cluster was created.
`PGHOST`, `PGPORT`, `PGUSER` and `PGDATABASE` are honoured, and `PSQL_BIN`
overrides the binary path.

```bash
cd portfolio-3-transactions-concurrency

./run_transactions.sh        # 01–03: COMMIT, ROLLBACK, SAVEPOINT -> evidence/
./run_concurrency.sh         # 01–04: the two-session races       -> evidence/
```

Each script runs its own fixture reset first, so they can be run individually and
in any order:

```bash
./concurrency/01_lost_update.sh
./concurrency/02_isolation_levels.sh
./concurrency/03_deadlock.sh
./concurrency/04_serializable.sh
```

Expect the deadlock demo to report psql status 3 for the victim and the
serializable demo to report status 3 for the transaction that loses the race.
That is the anomaly being observed, not a failure of the script. Each demo takes
between 4 and 12 seconds, almost all of it `pg_sleep`.

On a Windows checkout the executable bit may not survive clone; if `./` gives
"permission denied", prefix the command with `bash`.

The fixture is reset by `setup_test_data.sql`, which deletes and recreates only
the rows whose names start with `P3 `. The 1.35M seeded rows are never touched,
so the demos can be run against the full dataset without changing any result in
Portfolios 1 and 2.

---

## 12. Reflection

The single-session demos are the easy half: the database either commits or it
does not, and both outcomes are legible in the transcript. The two-session races
are where the interesting conclusions came from, and two of them were not what I
expected when I started.

The first is that the oversell (§5.1) produced **no error**. I had assumed a
constraint would catch a double sale; in fact every constraint was satisfied and
the damage was only visible by comparing the ledger with the stock total. A
correctness check that only looks for errors would have passed this system.

The second is how differently the same two scripts behave one isolation level
apart (§7). REPEATABLE READ made the anomaly *quieter* — no blocking, no error,
both transactions reporting success — while SERIALIZABLE made it loud and
recoverable. The level that fails fast is the one that is easier to operate, as
long as the caller actually retries.

If I rebuilt this, I would put the guarded `UPDATE` (§5.3) into the checkout from
the start and treat `FOR UPDATE` as the tool for multi-row decisions, because the
guard is one statement, holds no lock across a payment call, and its result is
self-describing. The lock is still the right answer when the decision cannot be
expressed as a single row's condition.
