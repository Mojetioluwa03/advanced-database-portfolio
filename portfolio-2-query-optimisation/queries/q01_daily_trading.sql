-- =============================================================================
--  Q01 - Daily trading summary for the last 30 days
--
--  Business question : what did the store take each day over the last month?
--  Access path      : range predicate on customer_order.order_date plus a
--                     status filter; ~8k of 200k orders qualify (4%).
--  Expected output  : 30 rows, one per trading day.
--
--  The as-of date is pinned to 2026-10-20, the day after the newest order in
--  the seeded dataset. CURRENT_DATE would make the window drift and the results
--  unreproducible after the assignment deadline.
-- =============================================================================
SELECT o.order_date::date                       AS trading_day,
       COUNT(*)                                 AS orders,
       SUM(o.grand_total)                       AS gross_revenue,
       ROUND(AVG(o.grand_total), 2)             AS avg_order_value
FROM customer_order o
WHERE o.status IN ('paid', 'shipped', 'delivered', 'refunded')
  AND o.order_date >= DATE '2026-10-20' - 30
  AND o.order_date <  DATE '2026-10-20'
GROUP BY 1
ORDER BY 1;
