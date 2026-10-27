-- =============================================================================
--  Experiment 2 - work_mem, and why a bigger value made q07 slower
--
--  q07 groups 200,000 orders into 48,593 customers and keeps the top 100. No
--  index changes how many rows must be aggregated, so the obvious lever is
--  memory. The hypothesis was that the default 4MB would force a spill and
--  raising it would help.
--
--  Result: there was no spill at either setting, and the larger work_mem made
--  the query ~40% slower, because it changed the plan:
--
--      4MB   GroupAggregate, 178 ms - input already arrives sorted by
--            customer_id from the index-only scan, so grouping costs no sort
--      64MB  HashAggregate, 249 ms - 30MB hash table, and the free ordering
--            from the index is thrown away
--
--  Run:  psql -d shopstack -f experiments/02_work_mem_sort.sql
-- =============================================================================
SET max_parallel_workers_per_gather = 0;
SET jit = off;

\echo '=== work_mem = 4MB (server default) ==='
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.customer_id,
       c.email,
       COUNT(*)                     AS orders,
       SUM(o.grand_total)           AS lifetime_spend,
       ROUND(AVG(o.grand_total), 2) AS avg_order_value,
       MIN(o.order_date)::date      AS first_order,
       MAX(o.order_date)::date      AS last_order
FROM customer_order o
JOIN customer c ON c.customer_id = o.customer_id
WHERE o.status IN ('paid', 'shipped', 'delivered', 'refunded')
GROUP BY o.customer_id, c.email
ORDER BY lifetime_spend DESC
LIMIT 100;

\echo '=== work_mem = 64MB ==='
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.customer_id,
       c.email,
       COUNT(*)                     AS orders,
       SUM(o.grand_total)           AS lifetime_spend,
       ROUND(AVG(o.grand_total), 2) AS avg_order_value,
       MIN(o.order_date)::date      AS first_order,
       MAX(o.order_date)::date      AS last_order
FROM customer_order o
JOIN customer c ON c.customer_id = o.customer_id
WHERE o.status IN ('paid', 'shipped', 'delivered', 'refunded')
GROUP BY o.customer_id, c.email
ORDER BY lifetime_spend DESC
LIMIT 100;
