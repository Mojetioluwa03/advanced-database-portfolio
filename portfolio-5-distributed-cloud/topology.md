# Topology — how ShopStack is distributed, and what it costs

This document describes the deployment built for Portfolio 5 and justifies each
decision against a measurement taken on it. The consistency argument that follows
from the layout is in [`cap-analysis.md`](cap-analysis.md); captured raw output is in
[`evidence/`](evidence/).

## 1. Constraints the design had to fit

The reference machine has no Docker, no administrative rights and no cloud account
(the same constraint recorded for Portfolios 1–4). PostgreSQL 16.15 runs from a
portable unzip, so the cluster is a set of data directories started with `pg_ctl`,
not containers. Two consequences shaped the work:

- **No Citus.** Citus is a separate extension, not part of the PostgreSQL
  distribution, so there is no distributed planner available. Distribution is built
  from `postgres_fdw`, which is in core.
- **Everything is local.** The "network" between shards is loopback TCP. That makes
  failure experiments controllable (`pg_ctl stop` is a faithful node loss) but means
  the absolute timings understate a real WAN deployment. The *ratios* — one shard
  versus three, pushed-down versus shipped rows — are the transferable result.

## 2. Layout

```
                       client
                         |
                         v
        +-----------------------------------+
        | router: port 5433, db             |
        | shopstack_router                  |
        |  postgres_fdw foreign tables      |
        |  order_all / customer_all / ...   |
        |  route_orders(), total_orders(),  |
        |  status_counts()                  |
        +----+-------------+-------------+--+
             |             |             |
      FDW    v             v             v
     +-----------+  +-----------+  +-----------+
     | EU shard  |  | UK shard  |  | US shard  |
     | 5441      |  | 5442      |  | 5443      |
     | 74 MB     |  | 108 MB    |  | 62 MB     |
     | 15.5k cust|  | 23.0k cust|  | 11.5k cust|
     | 62.1k ord |  | 91.9k ord |  | 46.0k ord |
     +-----+-----+
           | WAL (async streaming)
           v
     +-----------+
     | EU standby|
     | 5444      |   hot standby, read-only
     +-----------+

  port 5433 also still hosts db `shopstack` — the untouched Portfolio 1
  single node, kept as the baseline every distributed timing is compared to.
```

Five PostgreSQL servers on one machine: the Portfolio 1 cluster on 5433 (source and
router), the three shards, and a standby of the EU shard. Every shard holds the
complete Portfolio 1 schema; only the rows differ.

## 3. What is partitioned, and on which key

The case study does not have one access pattern, so it does not get one shard key.
It has two domains with different natural owners, and they are partitioned
separately.

| Domain | Tables | Shard key | Owner |
|---|---|---|---|
| Order | `customer`, `customer_address`, `cart`, `cart_item`, `customer_order`, `order_line`, `order_promotion`, `payment`, `shipment`, `shipment_line`, `return_request`, `review` | the **jurisdiction of the customer's default address** | the customer |
| Stock | `stock_level`, `stock_movement` | the **jurisdiction of the warehouse** | the warehouse |
| Reference | brand, category, attribute, attribute_value, product, product_category, product_variant, variant_attribute_value, supplier, product_supplier, promotion, warehouse | **not partitioned — replicated in full** | everyone |

The jurisdiction is `EU`, `UK` or `US`, taken from the address or warehouse region
(`shard/prepare_source.sql`). The mapping is materialised at build time into
`shardmap.customer_shard` and `shardmap.warehouse_shard` in the source database,
which is also what `shard/extract.sql` reads to decide which slice to export.

### 3.1 Why jurisdiction, and not order id or customer id hash

**1. It matches the queries the business actually runs.** Finance already reports by
region; customer service looks up an order knowing the customer; warehouse staff work
one distribution centre. A jurisdiction key keeps each of those inside one shard.
A hash key would spread one region's rows over all shards and turn every regional
report into a three-shard scan without shortening any single-row lookup — a hash is
only better when the access pattern is uniformly random by id, and it is not.

**2. It keeps the unit of consistency local.** An order, its lines, its payment and
its shipment are written by one checkout and must commit together. Under a
customer-jurisdiction key they are guaranteed to be in the same database, so the
Portfolio 3 transaction — including the `SELECT … FOR UPDATE` on stock — remains a
local transaction. Under a hash key the guarantee would depend on the hash function
and would have to be re-proved for every new table.

**3. It gives the failure domain a business meaning.** As §7 shows, losing a shard
loses one jurisdiction, and the other two keep serving. Losing a hashed shard would
degrade a random third of every region's requests instead.

**4. The stock domain has a different owner, and pretending otherwise would be
worse.** Stock movements are performed by a warehouse; the warehouse is where the
stock physically is. Co-locating movements with the warehouse makes the ledger write
local, which is the write that must never be lost. The price is paid at the edge
between the domains (§8), and it is paid openly rather than hidden behind a global
key that would not exist in reality.

The measured result of this choice is in §5: a point lookup costs 0.66 ms routed and
1.95 ms through the fan-out view — 3× the work, but only 1.3 ms of extra latency,
because each foreign scan is a local index lookup on a table one third the size.
Distribution is a real cost on point reads, but not a decisive one. It is decisive on
aggregates, and that is a separate problem (§5.2).

### 3.2 The replicated catalogue

The catalogue is copied whole to all three shards: 10,001 products and 21,561
variants. That is verifiable, not asserted — the same checksum on every shard:

```
           size  customers  orders  order_lines  stock_lv  movements  variants  md5(variant_id:sku)
eu         74 MB     15,476  62,135      137,048     6,947    105,452    21,561  94591b306d5920f755c2affe9c30d9b1
uk        108 MB     22,979  91,904      201,708    14,039    213,860    21,561  94591b306d5920f755c2affe9c30d9b1
us         62 MB     11,546  45,961      101,371     7,012    104,909    21,561  94591b306d5920f755c2affe9c30d9b1
source    264 MB     50,001 200,000      (whole)    27,998    424,221    21,561
```

Replication is right for this table and wrong for any other: every region reads the
catalogue on almost every request and nobody writes it at checkout pace. Copying it
means a product page never crosses the network, and the join from an order line to a
variant is always local. The cost is a write path that must reach all three shards.
**This build does not implement that write path** — the catalogue is re-extracted and
reloaded by `build_shards.sh`. A production system would make the catalogue a single
authoritative database and use logical replication to fan changes out, or keep it in
its own shard with a cache in front. That is a named alternative, not a hidden gap;
see §9.

## 4. Replication

One physical standby: the EU primary on 5441 streams WAL to a hot standby on 5444,
created with `pg_basebackup -D … -R -X stream` and started with the
`standby.signal` that `-R` writes. All three shards were initialised with
`wal_level = replica`, `max_wal_senders = 5` and `wal_keep_size = 64MB`
(`shard/build_shards.sh`), so any of them could host a standby; only EU does.

**Why EU.** It is the median shard by size (74 MB between 62 and 108), so the lag
numbers are not flattered by a tiny dataset, and it carries the catalogue, which is
the thing the README promised a replica for. A production deployment would give
every shard its own standby; one is enough to demonstrate and measure the mechanism.

**Why asynchronous.** Synchronous replication makes every commit wait for the
standby, which converts a replica failure into a primary outage unless there are
several standbys and a quorum. For a catalogue and a reporting replica, the narrow
staleness window is acceptable and the write path's independence is worth more. The
window is measured, not assumed:

```
replay paused on standby
primary quantity    : 3231
standby quantity    : 2231   <- stale, by design
lag bytes           : 18096
sender replay_lag   : 00:00:00.465417
catch-up after resume: 338 ms
```

(`evidence/e3_replication_lag.txt`.) The experiment pauses replay with
`pg_wal_replay_pause()` so the window can be observed; without that, the lag is
milliseconds and the transition is invisible. The number to report honestly is
"hundreds of milliseconds, and 338 ms to drain a 18 KB backlog on loopback". A WAN
replica would be slower and the same experiment would quantify it.

The standby is read-only and genuinely useful for reports — but it is a separate
failure domain, which §7 treats.

## 5. Routing and the aggregate problem

The router is a Postgres database (`shopstack_router`, port 5433) with:

- one foreign server and one user mapping per shard, `keep_connections 'on'` so a
  pooled backend does not re-authenticate on every query;
- six sharded tables × three shards = 18 foreign tables, built with generated column
  lists because `CREATE FOREIGN TABLE … (LIKE …)` is not supported;
- fan-out views (`order_all`, `customer_all`, `stock_all`, `movement_all`) that union
  the three foreign tables and tag each row with its shard;
- three routing functions: `route_orders(jurisdiction)` (one shard, key known),
  `total_orders()` and `status_counts()` (per-shard partial aggregates combined in
  the router).

### 5.1 Measured cost

Warm-up discarded, three runs, median of the three, server-side `EXPLAIN (ANALYZE)`
timings, all four runs inside one session (a fresh `psql` would pay FDW connection
setup and report that instead — in `e1` the fan-out lookup costs 71 ms on its first
execution and 1.9 ms once the shard connections are open, about 35 ms per new
connection).

| Query | Path | Median |
|---|---|---|
| point lookup, key known | one shard | **0.657 ms** |
| point lookup, key unknown | fan-out view | 1.948 ms |
| `count(*)`, key known (US) | one shard | 2.438 ms |
| `count(*)` | fan-out view | 196.942 ms |
| `count(*)`, whole table | single node | 15.353 ms |
| `GROUP BY status` | fan-out view | 225.453 ms |
| `count(*)` | partials per shard | **10.133 ms** |
| `GROUP BY status` | partials per shard | 31.812 ms |
| `GROUP BY status` | single node | 36.075 ms |

(`benchmarks/routing.csv`.)

### 5.2 Why the naive fan-out is 13× slower, and why the fix works

`count(*)` over `order_all` is 196.9 ms against 15.4 ms on one node — 12.8× the
work, not the 3× a naive "three shards, three scans" estimate would suggest. The
plan explains it (`evidence/e2_plan.txt`):

```
->  Append
      ->  Foreign Scan on shard.order_eu o
            Remote SQL: SELECT status FROM public.customer_order
      ->  Foreign Scan on shard.order_uk o_1
            Remote SQL: SELECT status FROM public.customer_order
      ->  Foreign Scan on shard.order_us o_2
            Remote SQL: SELECT status FROM public.customer_order
```

The planner sees an `Append`, not an aggregate over a partitioned table, so it cannot
push `count(*)` down: it fetches **one row per order — 200,000 rows — across three
foreign connections** and counts them locally. Through a view, `postgres_fdw` can only
push an aggregate when the foreign scan sits directly under it, which a `UNION ALL`
prevents.

The fix is to ask each shard for its partial and combine the partials in the router:

```
->  Foreign Scan
      Relations: Aggregate on (shard.order_eu)
      Remote SQL: SELECT status, count(*) FROM public.customer_order GROUP BY 1
```

Now three numbers, or eighteen rows for a six-status breakdown, cross the network
instead of 200,000, and the cost falls to 31.8 ms. That is **faster than the single
node's 36.1 ms** for the same group-by, and `total_orders()` (10.1 ms) beats the
single node's `count(*)` (15.4 ms). The
honest reading is not "distribution is faster" — it is that once the data is small
enough to sit in each shard's own buffer cache, three local scans of a third of the
table cost about what one scan of the whole table costs, and the router's overhead is
small. The point of the exercise is that the *wrong* federation strategy is an order
of magnitude worse, and the fix is two small SQL functions
(`router/setup_router.sql`).

This is also why `route_orders()` exists: an application that knows the jurisdiction
should not use the view at all. The view is a convenience for genuinely global
questions (reconciliation, ad-hoc analytics), and its cost is the price of not having
a distributed planner.

## 6. Cross-shard referential integrity

`stock_movement.ref_order_id` refers to `customer_order`, but the movement lives with
the warehouse and the order lives with the customer — and they are frequently in
different jurisdictions. A local foreign key cannot span that boundary, and
`postgres_fdw` foreign tables cannot enforce one either, so `shard/load.sql` drops it:

```sql
ALTER TABLE stock_movement DROP CONSTRAINT IF EXISTS stock_movement_ref_order_id_fkey;
```

That is a deliberate loss of a constraint, not an oversight, so it is quantified
(`evidence/e6_cross_shard_reference.txt`):

| Shard | Sale movements | …whose order is stored on another shard |
|---|---:|---:|
| EU | 98,505 | 67,651 |
| UK | 199,823 | 108,079 |
| US | 97,897 | 74,987 |
| **Total** | **396,225** | **250,717 (63.3%)** |

Two thirds of sale movements reference an order that is not in the same database.
A per-shard `LEFT JOIN` therefore reports them as "missing", and a naive reader would
conclude the data is broken. It is not: the router can resolve every one. The same
query run against `movement_all` joined to `order_all` finds **0 orphans in a 1,000-row
sample**, and produces examples of the intended shape:

```
 movement_shard | order_shard | movement_id | warehouse_id | ref_order_id
----------------+-------------+-------------+--------------+--------------
 uk             | eu          |       27997 |            1 |            1
 uk             | eu          |       27998 |            2 |            1
 uk             | eu          |       27999 |            1 |            1
```

So the integrity is *enforced at a different layer*: the shard cannot enforce it, the
router can detect violations, and the application must not create them. What is
missing is prevention — there is no global transaction that writes the movement and
the order together. `cap-analysis.md` §7 treats the consequence.

## 7. Failure behaviour

Two node failures were staged, both real process stops.

### 7.1 The replica dies (`evidence/e4_replica_down.txt`)

```
standby in recovery : t      replication senders : 1
-- pg_ctl -m fast stop
write accepted      : 2232   replication senders : 0
reading the standby : connection refused
-- restart
standby rows        : 62135  lag bytes : 0
```

The primary does not notice, does not block and does not wait: writes continue with
zero connected senders. Only the readers pointed at 5444 fail, and they must be
routed back to the primary. This is the direct consequence of choosing asynchronous
replication in §4, and it is the correct trade for a reporting replica.

### 7.2 A shard dies (`evidence/e5_shard_down.txt`)

```
all shards up        : customers via view 50001, EU-routed orders 62135
-- pg_ctl -m fast stop (US, port 5443)
EU-routed orders     : 62135                 <- still served
US-routed orders     : ERROR: could not connect to server "shard_us"
customers via view   : ERROR: could not connect to server "shard_us"
```

The blast radius is one jurisdiction for routed traffic, and **everything** for
fan-out traffic: a `UNION ALL` view has no partial success, so one missing shard makes
the whole query fail. That is the operational argument for keeping routing keys in
requests — a checkout that carries a jurisdiction degrades to "US customers cannot
check out", which is survivable, while a global query degrades to "nothing works".

What the application must do follows directly, and is written up in the P5 README
§4: route by jurisdiction, treat a shard error as a jurisdiction outage rather than
a database outage, keep the last catalogue copy cached, and queue writes for the
affected region instead of retrying them blindly. What this build does **not** have
is automatic failover: there is no Patroni, no streaming standby per shard, no VIP.
Promoting the EU standby is a manual `pg_ctl promote`. That is a limitation, stated
in §9, not a property being claimed.

## 8. What a user of the data sees

- **Point lookups** survive distribution: 0.66 ms routed, 1.95 ms fanned out.
- **Catalogue reads** never leave the shard: the product and variant rows are local.
- **Regional reports** are fast only if written against partial aggregates; the view
  is a trap (197 ms vs 10 ms).
- **Global aggregates** are affordable when pushed down as partials, and not
  otherwise.
- **Cross-shard references** exist at scale (63% of movements) and are reconciled,
  not prevented.
- **Failure** costs a jurisdiction for routed queries and all availability for
  fan-out queries.

## 9. Limitations and named alternatives

| Limitation | Consequence | Alternative if it mattered |
|---|---|---|
| No distributed planner (no Citus) | aggregates over views are unusable without hand-written partials | Citus shard/reference tables with a distributed planner; or a materialised global rollup refreshed on a schedule |
| Catalogue writes are a rebuild | catalogue changes require re-running `build_shards.sh` | single catalogue database + logical replication; or Citus reference table |
| No cross-shard transactions | movement/order write is not atomic; orphans are detectable, not prevented | saga with an outbox and reconciliation; or 2PC (`PREPARE TRANSACTION`) if both ends are PostgreSQL and the coordinator is trusted |
| No automatic failover | shard or replica loss needs an operator | Patroni + etcd, or a managed service (RDS/Aurora/Cloud SQL) |
| Loopback "network" | absolute timings understate WAN costs | repeat with `netem` delay, or deploy across two hosts |
| Single machine | no real partition between shards | separate hosts/AZs, which is what the failure experiments simulate |

## 10. Reproduction

```bash
# from the workspace root (holds .pg16 and .pgdata)
cd advanced-database-portfolio
bash portfolio-5-distributed-cloud/shard/build_shards.sh       # 5441/5442/5443 + router data
bash portfolio-5-distributed-cloud/router/setup_router.sh      # 5433: shopstack_router
bash portfolio-5-distributed-cloud/replication/setup_replica.sh # 5444: EU standby
bash portfolio-5-distributed-cloud/experiments/bench_routing.sh # benchmarks/routing.csv
bash portfolio-5-distributed-cloud/experiments/e3_replication_lag.sh
bash portfolio-5-distributed-cloud/experiments/e4_replica_down.sh
bash portfolio-5-distributed-cloud/experiments/e5_shard_down.sh
bash portfolio-5-distributed-cloud/experiments/e6_cross_shard_reference.sh
```

The experiments stop and restart real server processes; run them when no other work
is using ports 5441–5444.
