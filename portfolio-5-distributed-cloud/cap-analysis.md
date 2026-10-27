# Consistency, availability, and what each one costs

The shard layout is in [`topology.md`](topology.md). This document argues the
consistency requirement of each data domain, states what the deployment does when
part of it is unreachable, and names the alternative that was rejected. The numbers
come from [`evidence/`](evidence/); the transaction-level mechanics come from
Portfolio 3.

## 1. Using CAP precisely

CAP says that a replicated system subject to a network partition must sacrifice
either linearizability (one logical copy) or availability (every reachable node
answers). Two mechanisms in this deployment are replicated, and CAP applies to both:

- the **catalogue**, copied whole to each shard;
- the **EU shard**, which has a physical streaming standby.

Sharding itself is *not* a CAP trade-off. Three shards holding disjoint slices are
not replicas: losing one loses data, not freshness. Two different problems hide
behind "the shard is down", and they deserve different names:

| Problem | Applies to | Measured here |
|---|---|---|
| Partition between copies | catalogue copies, EU primary/standby | e3, e4 |
| Partial availability (blast radius) | a shard holding a slice | e5 |
| Atomic commitment across shards | checkout writing order + stock | e7 |

Atomic commitment is the two-generals problem, not CAP: no partition is required for
it to bite, and no replication setting fixes it. Calling the whole design "AP" or
"CP" would flatten three different questions into one word, so the rest of this
document answers them per domain.

PACELC adds the case that actually obtains most of the time — no partition — where
the choice is **latency versus consistency**: pay a round trip to be current, or
serve a possibly stale copy quickly.

## 2. The loss function decides

Consistency is not a virtue in itself; it is worth what a stale read or a refused
write costs. Those costs differ by an order of magnitude between domains, which is
why one posture for the whole system would be wrong.

| Domain | A stale read costs | A refused write costs | Posture |
|---|---|---|---|
| Catalogue (product, variant, brand, category) | a shopper sees an old description for a moment | a merchandiser retries | **EL** normally, **A** under partition |
| Stock level | an oversell — refund, goodwill, negative stock | a deferred sale | **CP** |
| Order, payment, shipment | a customer not seeing their own order | a lost sale, but never a double charge | **CP** |
| Stock movement ledger | a report that is minutes behind | nothing, it is append-only | **EL** for reads, durable for writes |
| Reporting replica reads | a stale dashboard | the report fails over to the primary | **EL** |

## 3. Catalogue: latency first, availability under partition

Every region reads the catalogue on nearly every request and none writes it at
checkout pace, so it is replicated in full: 10,001 products, 21,561 variants, and the
same checksum on all three shards (topology.md §3.2). A product page is answered
without leaving the shard.

**Why staleness is safe here — the price snapshot.** If the catalogue were stale at
checkout, a customer could be charged an old price. That cannot happen, because
`order_line` stores `unit_price` and `line_total` at the moment of sale
(`portfolio-1-database-design/schema.sql:265-275`), and a check constraint ties
`line_total` to `quantity * unit_price`. The order is a snapshot of what was agreed;
a later catalogue change cannot rewrite history. This is the difference between a
domain where eventual consistency is fine and one where it is not: the catalogue is
reference data, and the transaction copied what it needed.

**What the classification would be if the copies were continuously replicated.** With
one authoritative catalogue and asynchronous fan-out, a merchandiser's change would
appear on their own shard immediately and on the others after a delay. Under
partition, each shard keeps serving its copy (**A**) and the copies converge when the
partition heals. With no partition, reading locally is faster than checking a master
(**EL**). That is the correct setting for this domain.

**What the build actually does.** The copies are refreshed by re-extracting and
reloading them in `build_shards.sh`; there is no continuous replication path. That
avoids divergence by construction but makes a catalogue update a rebuild. It also
means the deployment cannot yet demonstrate the convergence half of the argument. A
single catalogue database with logical replication to each shard is the named
alternative (topology.md §9). Accepting writes on all three shards would be the
wrong answer: concurrent edits to the same product would be resolved last-writer-wins
and silently lose one of them.

## 4. Stock: strongly consistent, and sharding does not fix the bug portfolio 3 found

Stock is the domain where the business case for consistency is clearest: an oversell
is money out of the door (refund, goodwill, a negative on-hand that blocks future
sales), while a refused sale is a deferred sale. The requirement is not "linearizable
across the world" — it is **one writer per SKU**, deciding on committed data.

Portfolio 3 established that the naive pattern does not meet it. In
`portfolio-3-transactions-concurrency/README.md` §5.1 two sessions read one unit,
each sleep through a payment call, and each write back zero: two paid orders, two
sale movements, one unit ever existed, **and no constraint fired**, because neither
session asked the database to do arithmetic. The constraint checks the value written,
not the decision made on stale data. §5.2 and §5.3 fix it with `SELECT … FOR UPDATE`
and with a guarded `UPDATE … WHERE quantity >= 1` that asks how many rows changed.

**Sharding gives that decision a single serialisation point and nothing more.** A
warehouse's stock rows live on exactly one shard (topology.md §3), so the guarded
update runs as an ordinary local transaction with row locks — the same guarantee as
Portfolio 3, without any distributed coordination. It would be wrong to claim
distribution improves the correctness of the decrement: the isolation level does
that, and it did so on one node. What distribution changes is *where the decision
happens*, and therefore what fails when a node fails.

**Under partition: refuse.** If the warehouse's shard is unreachable, the decrement
cannot be decided on committed data, so the sale is refused. The deployment already
behaves this way for routed traffic: `evidence/e5_shard_down.txt` shows EU orders
still served at 62,135 while every US-routed request fails with
`could not connect to server "shard_us"`. Checkout must turn that into "US
checkouts are unavailable", not into a retry loop and certainly not into an
optimistic decrement to be reconciled later. Accepting the write and reconciling
would trade a deferred sale for a possible oversell — the wrong direction on this
loss function.

## 5. Orders and payments: CP, inside one shard

An order, its lines, its payment and its shipment are written by one checkout and
must commit or fail together. The customer-jurisdiction key puts them in the same
database, so this remains the Portfolio 3 transaction: local, ACID, with the
isolation-level behaviour already measured there (write skew survives REPEATABLE
READ, and SERIALIZABLE returns 40001 to retry). Under partition the customer's shard
is unavailable and checkout for that customer stops (**C** over **A**). Money makes
that the easy call: refusing is recoverable, double-charging is not.

The consequence for reads is **read-your-writes**, and it interacts with the replica
(§8): immediately after a commit, the customer's own order must be read from the
primary. A replica read could miss it for the length of the lag window.

## 6. The ledger: durable, append-only, weak only at its edge

`stock_movement` is co-located with the warehouse that performed the movement, and a
sale movement is written in the same local transaction as the stock decrement. Stock
and ledger therefore cannot disagree *within* a shard — that is the property the
co-location buys, and it is why the stock domain was not keyed by customer.

What is weak is the movement's reference to `customer_order`: 63.3% of sale movements
(250,717 of 396,225) point at an order stored on another shard, because the warehouse
that moved the goods and the customer who bought them are in different jurisdictions
(topology.md §6). The foreign key is dropped, the router can still resolve every
reference (`evidence/e6_cross_shard_reference.txt`: 0 orphans in a 1,000-row sample),
and the application must not create dangling ones.

For reads, the ledger is append-only and analysed in arrears, so a replica that is
seconds behind is acceptable (**EL**). For writes, durability is not negotiable: a
movement that is acknowledged but lost means physical stock and recorded stock drift
apart with no way to reconstruct what happened.

## 7. The cross-shard checkout: a saga, because two-phase commit is not available

Checkout is the one operation that touches two shards: the order on the customer's
shard and the stock decrement (plus its movement) on the warehouse's shard. If those
could be prepared together, 2PC would make the pair atomic. They cannot:

```
BEGIN
UPDATE shard.stock_us SET quantity = quantity WHERE warehouse_id = -1
ERROR:  cannot PREPARE a transaction that has operated on postgres_fdw foreign tables
```

(`evidence/e7_no_2pc.txt`.) `postgres_fdw` runs the remote statement in its own
transaction; once one has executed, the local transaction is no longer preparable.
The local half of the mechanism is also off in this build
(`max_prepared_transactions = 0`). So there is no distributed transaction to be had
from this stack, and claiming atomic checkout would be false.

The design therefore uses a saga, ordered so that the recoverable failure is the one
that can happen:

1. **Order first.** Write the order, lines and payment on the customer's shard and
   commit. The order is now real and visible; nothing physical has moved.
2. **Then stock.** Call the warehouse shard: guarded decrement plus the sale
   movement, in one local transaction there. If the guard matches no row, the
   warehouse is out of stock and step 1 is compensated by cancelling the order and
   refunding the payment.
3. **Idempotent retry.** The stock call carries the order line as its key, so a
   retry after a timeout cannot decrement twice. Without that, the retry that every
   network timeout invites would be a second sale movement.
4. **Reconcile.** Any order that committed but never got a movement is an orphan of
   the opposite shape to the ones e6 looks for. The router can find both: a movement
   without an order, and an order whose lines have no movement. The reconciliation
   query is the substitute for the foreign key, and running it is an operational
   responsibility rather than a database guarantee.

The ordering matters. Decrementing stock first and then failing to record the order
loses stock silently and leaves a movement pointing at nothing; recording the order
first and failing to decrement leaves a sale that is visible and can be cancelled.
The second is the failure the business can see and fix.

**What is implemented and what is not.** The router serves reads across shards and
each shard accepts writes directly; the saga above is the design for the checkout
write path, not something this deployment executes. That boundary is deliberate:
building a saga without a request-scoped idempotency key and a compensator would
produce a demo, not a mechanism. The alternative to a saga is a stack that supports
distributed transactions (Citus, or a transaction manager over XA), and that is
listed in topology.md §9.

## 8. Reads from the replica: a measured consistency window

The EU standby is asynchronous (§4 of topology.md), so a read served from 5444 can
miss a commit that has already returned on 5441. The window was measured by pausing
replay, which widens it from milliseconds to something observable:

```
primary quantity : 3231        standby quantity : 2231   <- stale
lag bytes        : 18096       sender replay_lag : 465 ms
catch-up         : 338 ms      lag after         : 0
```

(`evidence/e3_replication_lag.txt`.) Two rules follow, and they are the whole
read-your-writes story:

- Reads that follow a write in the same session — a customer viewing the order they
  just placed, a merchandiser checking an edit — go to the primary.
- Analytics, dashboards and catalogue browsing may use the replica, and should be
  labelled with the lag so nobody reads a stale number as current.

The consistency-first alternative is `synchronous_commit = remote_apply`, which makes
the primary wait until the standby has applied the commit. It removes the window and
buys it with commit latency on every write, and — more seriously — it makes the
primary's write path depend on the standby's health unless several standbys and a
quorum are configured. For a reporting replica that is the wrong trade; for a
catalogue replica feeding checkout it might be the right one.

Replica loss is already tested (`evidence/e4_replica_down.txt`): writes continue with
zero connected senders, the standby refuses connections, and restarting it catches
up to zero lag. The replica failing costs the *readers*, which must fail over to the
primary; it does not cost the writer, which is the point of asynchronous replication.

## 9. PACELC summary

| Domain | If Partition | Else | Why |
|---|---|---|---|
| Catalogue copies | **A** — serve the local copy | **EL** — read locally | reference data; checkout snapshots price |
| Stock level | **C** — refuse the decrement | **EC** — local row locks | overselling is a financial loss |
| Order / payment | **C** — refuse checkout | **EC** — single-shard ACID | double charge is unrecoverable |
| Movement ledger | **C** for writes, **A** for reads | **EL** for reports | append-only; lag is tolerable, loss is not |
| EU standby reads | **A** — stale reads | **EL** — serve the replica | reporting only; readers fail over |
| Cross-shard checkout | not a CAP case — saga + compensation | **EC** per shard, reconciled across | 2PC unavailable (e7) |

## 10. Verdict

The deployment does not have a system-wide consistency setting, and that is the
result rather than an omission. Money and stock are strongly consistent, single-owner
and local: one warehouse shard decides a decrement, one customer shard commits an
order, and both refuse to proceed when their node is unreachable. The catalogue and
reports are allowed to be stale because the sale snapshots the price and a dashboard
is not a ledger. The ledger is durable and append-only, weak only where it points
across a shard, and reconciled by the router.

The honest gaps are named in topology.md §9: no distributed transactions, no
catalogue write replication, no failover automation, and a loopback "network" that
understates WAN latency. Each has an alternative that would be chosen if the
constraint that ruled it out — a single machine, no extensions, no Docker — were
lifted.
