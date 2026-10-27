# Portfolio 5 — Distributed and Cloud Database Exercise

**Marks:** 6 of 40
**Status:** not started

## Scope

Taking ShopStack from a single node to a distributed deployment, and reasoning about
the trade-offs that appear when data lives in more than one place.

Planned work:

1. **Sharding design** — a shard key justified against the access patterns. The
   natural candidate is region: `stock_level` and `customer_order` partition cleanly by
   warehouse region and customer region respectively, while the product catalogue is
   replicated everywhere because every region reads it.
2. **Replication** — a primary plus streaming read replica for the catalogue, with
   measured replication lag and a demonstration of serving reports from the replica.
3. **Availability and consistency** — a written analysis of the CAP trade-off per data
   domain: stock must be strongly consistent (overselling is a financial loss), product
   descriptions can be eventually consistent, and the movement ledger is append-only so
   it tolerates lag.
4. **Failure behaviour** — what happens to checkout when a shard is unreachable, and
   what the application must do about it.
5. **Deployment evidence** — containerised configuration, cluster topology diagram and
   captured output proving data is distributed.

## Planned files

```
topology.md           shard and replica layout, with the shard-key justification
pg-primary/           primary configuration
pg-replica/           replica configuration, recovery settings
shard-router/         routing/federation approach
benchmarks/           read/write timings, replication lag measurements
cap-analysis.md       consistency requirements per data domain
README.md             summary and conclusions
```
