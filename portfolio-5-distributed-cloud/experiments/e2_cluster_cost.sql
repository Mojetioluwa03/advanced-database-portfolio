-- E2: the price of distribution. The same aggregate, once on the single node
-- and once across three shards, then a per-shard pushdown.
--   psql -h 127.0.0.1 -p 5433 -U postgres -d shopstack -f experiments/e2_cluster_cost.sql
--
-- Both databases live on port 5433, so \c switches between them in one session.
\pset pager off
\timing on

\echo '--- single node (Portfolio 1 database, 200k orders in one table)'
SELECT count(*) AS orders, sum(grand_total) AS revenue FROM customer_order;
SELECT status, count(*) FROM customer_order GROUP BY status ORDER BY status;

\c shopstack_router

\echo '--- three shards through the router (same rows, split three ways)'
SELECT count(*) AS orders, sum(grand_total) AS revenue FROM order_all;
SELECT status, count(*) FROM order_all GROUP BY status ORDER BY status;

\echo '--- does the aggregate run on the shards or in the router?'
EXPLAIN (VERBOSE, COSTS OFF)
SELECT status, count(*) FROM order_all GROUP BY status ORDER BY status;
