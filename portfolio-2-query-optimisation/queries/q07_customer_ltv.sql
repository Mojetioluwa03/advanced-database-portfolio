-- =============================================================================
--  Q07 - Top 100 customers by lifetime value
--
--  Business question : who are the highest-value customers, and how recently
--                      did each of them buy?
--  Access path      : full scan of 200k orders aggregated into 50k customers,
--                     then the top-100 sort.
--  Expected output  : 100 rows.
--
--  This is the query most likely to be I/O bound rather than CPU bound: every
--  order row is visited, so the win comes from reading fewer pages (a covering
--  index) rather than from seeking.
-- =============================================================================
SELECT o.customer_id,
       c.email,
       COUNT(*)                        AS orders,
       SUM(o.grand_total)              AS lifetime_spend,
       ROUND(AVG(o.grand_total), 2)    AS avg_order_value,
       MIN(o.order_date)::date         AS first_order,
       MAX(o.order_date)::date         AS last_order
FROM customer_order o
JOIN customer c ON c.customer_id = o.customer_id
WHERE o.status IN ('paid', 'shipped', 'delivered', 'refunded')
GROUP BY o.customer_id, c.email
ORDER BY lifetime_spend DESC
LIMIT 100;
