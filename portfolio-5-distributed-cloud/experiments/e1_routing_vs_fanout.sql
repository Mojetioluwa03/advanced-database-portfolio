-- E1: a request that carries its jurisdiction touches one shard; the same
-- request through the fan-out view touches all three.
--   psql -d shopstack_router -f experiments/e1_routing_vs_fanout.sql
\pset pager off
\timing on

SELECT min(order_id) AS oid FROM shard.order_us \gset

\echo '--- routed: one shard, key known'
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT * FROM shard.order_us WHERE order_id = :oid;

\echo '--- fan-out view: same row, three shards contacted'
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT * FROM order_all WHERE order_id = :oid;

\echo '--- routed aggregate (one shard)'
SELECT count(*) FROM route_orders('us');

\echo '--- fan-out aggregate (three shards)'
SELECT count(*) FROM order_all;

\echo '--- rows per shard through the view'
SELECT shard, count(*) FROM order_all GROUP BY shard ORDER BY shard;
