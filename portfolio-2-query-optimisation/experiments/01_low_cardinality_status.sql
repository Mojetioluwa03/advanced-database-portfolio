-- =============================================================================
--  Experiment 1 - is a plain index on a low-cardinality column worth it?
--
--  Hypothesis: customer_order.status has six values and appears in the WHERE
--  clause of q01, q02, q07 and q08, so indexing it should speed them up.
--
--  Result: the answer is "it depends which value you ask for", and all four of
--  those queries ask for the common values, so the index does not help them:
--
--      status = 'paid'      13,979 of 200,000 rows (7%)   -> Bitmap Index Scan
--      status = 'delivered' 139,932 of 200,000 rows (70%) -> Seq Scan
--
--  Run:  psql -d shopstack -f experiments/01_low_cardinality_status.sql
-- =============================================================================
SET max_parallel_workers_per_gather = 0;
SET jit = off;

CREATE INDEX IF NOT EXISTS ix_order_status ON customer_order (status);
ANALYZE customer_order;

\echo '=== rare value: status = paid (13,979 of 200,000 rows, ~7%) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS orders, SUM(grand_total) AS revenue
FROM customer_order
WHERE status = 'paid';

\echo '=== common value: status = delivered (139,932 of 200,000 rows, ~70%) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS orders, SUM(grand_total) AS revenue
FROM customer_order
WHERE status = 'delivered';

\echo '=== index size versus table size ==='
SELECT pg_size_pretty(pg_relation_size('customer_order')) AS heap_size,
       pg_size_pretty(pg_relation_size('ix_order_status')) AS index_size;

DROP INDEX IF EXISTS ix_order_status;
