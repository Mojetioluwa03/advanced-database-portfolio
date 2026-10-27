# Portfolio 5 — Distributed and Cloud Database Exercise

**Marks:** 6 of 40
**Status:** complete — three jurisdiction shards, one streaming standby, a
`postgres_fdw` router, seven experiments, measured routing costs
**Stack:** PostgreSQL 16.15 portable clusters, `postgres_fdw`, loopback TCP
**Analysis:** [`topology.md`](topology.md) (layout and shard-key justification),
[`cap-analysis.md`](cap-analysis.md) (consistency per data domain)

---

## 1. What this activity delivers

| Requirement | Demonstrated by | Evidence |
|---|---|---|
| A sharding design with a justified key | Jurisdiction key for the order domain, warehouse key for the stock domain, replicated catalogue | `topology.md` §3, `shard/prepare_source.sql`, `shard/extract.sql` |
| Replication with measured lag | EU primary → hot standby via `pg_basebackup -R -X stream` | `replication/setup_replica.sh`, `evidence/e3_replication_lag.txt` |
| The CAP/PACELC trade-off per domain | One posture per data domain, with the alternative named | `cap-analysis.md` |
| Failure behaviour | A shard stopped, a replica stopped, fan-out versus routed queries | `evidence/e4_replica_down.txt`, `evidence/e5_shard_down.txt` |
| Proof the data is distributed | Per-shard row counts, database sizes, identical catalogue checksum, cross-shard references | §3, `evidence/e6_cross_shard_reference.txt` |
| Measured cost of distribution | Routed vs fanned-out vs single-node timings | `benchmarks/routing.csv`, `evidence/e1…e2` |

**Deviation from the original plan, stated up front.** The planned work item 5 says
"containerised configuration". The machine used for all five portfolios has no
Docker and no administrative rights (root README, Route B), so the deployment
evidence is process- and port-based: five PostgreSQL server processes on 5433–5444,
each a portable data directory started with `pg_ctl`. Nothing here is containerised,
and no containerisation claim is made. The topology, the routing and the failure
experiments are the same ones a container deployment would need; only the packaging
differs.

---

## 2. The layout in one table

| Node | Port | Database | Holds | Size |
|---|---|---|---|---|
| Router | 5433 | `shopstack_router` | 18 foreign tables, 4 fan-out views, 3 routing functions | — |
| Source | 5433 | `shopstack` | the untouched Portfolio 1 single node, kept as the baseline | 264 MB |
| EU shard | 5441 | `shopstack_eu` | 15,476 customers, 62,135 orders, 105,452 movements | 74 MB |
| UK shard | 5442 | `shopstack_uk` | 22,979 customers, 91,904 orders, 213,860 movements | 108 MB |
| US shard | 5443 | `shopstack_us` | 11,546 customers, 45,961 orders, 104,909 movements | 62 MB |
| EU standby | 5444 | `shopstack_eu` | physical streaming replica of 5441, read-only | 74 MB |

Every shard holds the complete schema and the complete catalogue (10,001 products,
21,561 variants — same checksum on all three); only the transactional rows are
partitioned. The shard key, the rejected alternatives and the catalog-replication
argument are in [`topology.md`](topology.md) §3.

---

## 3. Results

### 3.1 Routing costs what the access pattern implies

Median of three runs after a discarded warm-up, server-side `EXPLAIN (ANALYZE)`
timing, all runs inside one session (`benchmarks/routing.csv`):

| Query | Path | Median |
|---|---|---|
| point lookup, key known | one shard | **0.657 ms** |
| point lookup, key unknown | fan-out view | 1.948 ms |
| `count(*)` | one shard (US) | 2.438 ms |
| `count(*)` | fan-out view | 196.942 ms |
| `count(*)` | single node | 15.353 ms |
| `count(*)` | partials per shard | **10.133 ms** |
| `GROUP BY status` | fan-out view | 225.453 ms |
| `GROUP BY status` | partials per shard | 31.812 ms |
| `GROUP BY status` | single node | 36.075 ms |

Three findings, in order of how much they mattered:

1. **Point reads survive distribution.** A keyed lookup costs 0.66 ms; the same
   lookup without the key costs 1.95 ms because it visits three shards. The
   absolute penalty is 1.3 ms — distribution is not free, but it is not the
   obstacle. The first call in a fresh session costs 71 ms, almost all of it FDW
   connection setup (`evidence/e1_routing_vs_fanout.txt`); `keep_connections 'on'`
   and a warm session are what make the medians honest.
2. **The fan-out view destroys aggregate pushdown.** `count(*)` through `order_all`
   is 12.8× the single node and `sum(grand_total)` through the same view is 4.1×
   (`evidence/e2_single_vs_cluster.txt`: 158 → 642 ms), because the planner cannot
   push the aggregate through a `UNION ALL` and ships one row per order across the
   wire. The plans are in `evidence/e2_plan.txt`.
3. **Per-shard partial aggregates fix it, and then some.** Asking each shard for
   `count(*)`/`count(*) GROUP BY status` and combining the partials in the router
   costs 10.1 ms and 31.8 ms — both *faster* than the single node's 15.4 and
   36.1 ms. The explanation is not that distribution is faster: three scans of a
   third of the table, each in its own cache, cost about what one scan of the whole
   table costs, and the router's overhead is small. The lesson is that the wrong
   federation strategy is an order of magnitude worse than the right one, and the
   right one is two small SQL functions.

### 3.2 Replication

EU primary → standby, asynchronous streaming. With replay paused to make the window
observable: primary commits `2231 → 3231`, standby still reads 2231, lag **18,096
bytes / 465 ms**, catch-up after resume **338 ms** to zero lag
(`evidence/e3_replication_lag.txt`). The window without pausing is milliseconds; the
experiment exists to put a number on it rather than assert it.

Killing the standby leaves the primary writing with **zero replication senders**;
only the readers pointed at 5444 fail, and a restart catches up to zero lag
(`evidence/e4_replica_down.txt`). That is the point of asynchronous replication and
the reason the replica is used for reports, not for checkout.

### 3.3 Failure: a jurisdiction outage, not a database outage

With the US shard stopped, EU-routed queries still return 62,135 orders; US-routed
queries fail with `could not connect to server "shard_us"`, and **every** fan-out
query fails, because a `UNION ALL` view has no partial success
(`evidence/e5_shard_down.txt`). Restarting the shard restores both 45,961 US orders
and the 50,001-customer fan-out.

This is the single most operationally important result in the portfolio: routing
keys convert an infrastructure failure into a business-scoped one.

### 3.4 Cross-shard integrity

`stock_movement` is co-located with the warehouse, but its `ref_order_id` points at
orders owned by customers, and **63.3% of sale movements (250,717 of 396,225)
reference an order stored on another shard**. The foreign key is dropped on the
shards; the router resolves every reference — 0 orphans in a 1,000-row sample
(`evidence/e6_cross_shard_reference.txt`). Prevention is not implemented, only
detection: `cap-analysis.md` §7 explains why a saga is the only option once
`postgres_fdw` refuses `PREPARE TRANSACTION` (`evidence/e7_no_2pc.txt`).

---

## 4. Failure behaviour, and what the application must do

The database's behaviour is measured; the application's obligations follow from it.

1. **Carry the jurisdiction with the request.** A checkout, an order lookup and a
   warehouse pick all know their region. Route them to one shard. The fan-out view
   is for genuinely global questions only — reconciliation and ad-hoc analytics —
   because it fails as a whole and costs 13× more.
2. **Treat a shard error as a regional outage.** `could not connect to server
   "shard_us"` means US traffic is degraded, not that ShopStack is down. EU and UK
   customers must keep checking out.
3. **Never retry a stock decrement blindly.** A timeout is not a failure; the
   decrement may have committed. The retry must carry the order line as an
   idempotency key, or it becomes a second sale movement. This is the same
   discipline Portfolio 3 applied to the guarded `UPDATE`.
4. **Read your own writes from the primary.** A customer who has just placed an
   order must not read it from the standby; the lag window is measured in §3.2.
5. **Keep serving a stale catalogue rather than failing** — the product page is
   reference data, and the sale snapshots `unit_price` into `order_line`.
6. **Reconcile on a schedule.** The router can find both orphan shapes: a movement
   whose order is missing, and an order whose lines never got a movement. That query
   is the substitute for the dropped foreign key, so it has to run.

---

## 5. Experiments

| # | What it asks | Finding |
|---|---|---|
| `e1_routing_vs_fanout.sql` | what routing buys on a point read | 1.57 ms routed vs 71.4 ms fanned out on a cold connection |
| `e2_cluster_cost.sql` | the price of distribution on aggregates | 158 → 642 ms for `count(*)+sum`, and the plan shows why |
| `e3_replication_lag.sh` | how wide the consistency window is | 18 KB / 465 ms paused, 338 ms to catch up |
| `e4_replica_down.sh` | does losing the standby stop writes | no; zero senders, writes continue, readers fail |
| `e5_shard_down.sh` | what one shard loss costs | one jurisdiction routed, everything fanned out |
| `e6_cross_shard_reference.sh` | how often the ledger points across shards | 63.3% of sale movements; 0 orphans resolvable by the router |
| `e7_no_two_phase_commit.sh` | can order + stock commit atomically | no — `cannot PREPARE a transaction that has operated on postgres_fdw foreign tables` |

`bench_routing.sh` is the measurement harness behind §3.1; it discards a warm-up,
takes three timed runs and reports the median, the discipline used in Portfolios 2
and 4.

---

## 6. Limitations

- **Not a benchmark.** Five server processes on one laptop, loopback TCP, warm
  caches. The numbers compare work done per query; they say nothing about throughput
  or WAN latency. A real deployment would repeat e2 with network delay.
- **Process stops are not partitions.** `pg_ctl stop` gives connection refused, which
  is a faithful node loss. It does not reproduce a network partition where the node
  is alive but unreachable, nor a split-brain. No claim is made about behaviour
  under those.
- **No distributed transactions.** Checkout across two shards is analysed as a saga,
  not implemented (`cap-analysis.md` §7). The router serves reads; the writes in the
  failure experiments are direct to the owning shard.
- **The catalogue is rebuilt, not replicated.** Copies are identical because
  `build_shards.sh` reloads them, not because a replication stream keeps them so. A
  catalogue write path is a named gap.
- **One standby, no failover.** Only the EU shard has a replica, and promoting it is
  a manual `pg_ctl promote`. There is no Patroni, no quorum, no VIP.
- **Four of the five requirements are met as specified; containerisation is not.**
  See §1.
- **The stock domain's second edge is untested.** Transfers between warehouses would
  require a decision spanning two stock shards; the dataset has none, and no design
  is claimed for it.

---

## 7. Reproducing

From the repository root, with the Portfolio 1 cluster running on 5433 (root README,
Route A or B):

```bash
bash portfolio-5-distributed-cloud/shard/build_shards.sh        # 5441/5442/5443
bash portfolio-5-distributed-cloud/router/setup_router.sh       # shopstack_router on 5433
bash portfolio-5-distributed-cloud/replication/setup_replica.sh # 5444

bash portfolio-5-distributed-cloud/experiments/bench_routing.sh
bash portfolio-5-distributed-cloud/experiments/e3_replication_lag.sh
bash portfolio-5-distributed-cloud/experiments/e4_replica_down.sh
bash portfolio-5-distributed-cloud/experiments/e5_shard_down.sh
bash portfolio-5-distributed-cloud/experiments/e6_cross_shard_reference.sh
bash portfolio-5-distributed-cloud/experiments/e7_no_two_phase_commit.sh
```

The scripts locate PostgreSQL at `../../.pg16/pgsql/bin` (the workspace root beside
this repository) and the shard data at `../../.pgshards`. `build_shards.sh` is
idempotent: it keeps the data directories and rebuilds the databases. The failure
experiments stop and start real servers, so do not run them alongside other work on
ports 5441–5444.

To rebuild the standby from scratch, `bash replication/setup_replica.sh --rebuild`.

---

## 8. Reflection

The result I did not expect was the partial aggregate beating the single node. I
expected distribution to cost something — a third of the scan in each shard, plus
the network, should roughly match one scan — and I wrote the conclusion as "parity at
best". The measurement said 10.1 ms against 15.4 ms for `count(*)` and 31.8 against
36.1 for the status breakdown. The explanation I believe is cache locality: each
shard's heap is a third of the size, so each scan is fully resident, and the router
only moves eighteen rows. I have deliberately not claimed distribution is faster;
the transferable fact is that the naive fan-out is thirteen times worse, and the
number to quote is the size of that mistake, not the small win that replaces it.

The second surprise was the size of the cross-shard edge. The design premise — stock
follows the warehouse, orders follow the customer — is right for each domain in
isolation, and I expected a minority of movements to point across the boundary. It
is 63%. Any order shipped from a warehouse outside the customer's own jurisdiction
produces one, and that is most of them. The alternative I considered was keying
movements by the order's customer so the reference stays local; I rejected it because
the ledger's primary readers are warehouse staff, and fanning out every stock query
to satisfy a reference that is only checked by reconciliation would move the cost
from a periodic query to every pick. The judgement call I am least certain of is
therefore not the shard key but the assumption that reconciliation is an acceptable
substitute for a foreign key. It is defensible only because the reconciliation query
exists and is cheap; if it were expensive, the key would have to change.
