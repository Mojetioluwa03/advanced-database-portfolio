-- =============================================================================
--  Experiment 3 - an index the planner correctly refused to use
--
--  q08 aggregates ~73k in-window delivered shipments into 5 carriers. The
--  candidate index was meant to make that an index-only scan:
--
--      CREATE INDEX ix_shipment_delivered ON shipment (carrier)
--          INCLUDE (dispatched_at, delivered_at) WHERE status = 'delivered';
--
--  Result: the planner kept the sequential scan and the runtime did not move.
--  6MB of index was created to serve a query that has to read ~90% of the
--  table's rows anyway; random index pages would be worse than a heap scan.
--  It was removed from indexes.sql rather than kept "just in case".
--
--  The honest fix for q08 is not an index at all: pre-aggregate into a daily
--  shipment fact table (or a materialised view refreshed nightly) so the report
--  reads 365 rows instead of 149k.
--
--  Run:  psql -d shopstack -f experiments/03_rejected_shipment_index.sql
-- =============================================================================
SET max_parallel_workers_per_gather = 0;
SET jit = off;

CREATE INDEX IF NOT EXISTS ix_shipment_delivered
    ON shipment (carrier) INCLUDE (dispatched_at, delivered_at)
    WHERE status = 'delivered';
ANALYZE shipment;

\echo '=== candidate had no effect: still a Seq Scan ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.carrier,
       COUNT(*)                                    AS delivered_shipments,
       ROUND(AVG(EXTRACT(EPOCH FROM (s.delivered_at - s.dispatched_at)) / 86400.0), 2)
                                                   AS avg_days_in_transit,
       COUNT(*) FILTER (WHERE s.delivered_at - s.dispatched_at <= INTERVAL '5 days')
                                                   AS on_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.delivered_at - s.dispatched_at <= INTERVAL '5 days')
             / COUNT(*), 1)                        AS on_time_pct
FROM shipment s
WHERE s.status = 'delivered'
  AND s.dispatched_at >= DATE '2025-10-20'
GROUP BY s.carrier
ORDER BY on_time_pct DESC, s.carrier;

\echo '=== cost of the candidate: a third of the heap, but 90% of its rows are needed ==='
SELECT pg_size_pretty(pg_relation_size('shipment'))              AS heap_size,
       pg_size_pretty(pg_relation_size('ix_shipment_delivered')) AS index_size;

DROP INDEX IF EXISTS ix_shipment_delivered;
