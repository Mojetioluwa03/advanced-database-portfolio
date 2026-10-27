-- =============================================================================
--  Q02 - Top 20 products by revenue over the last 90 days
--
--  Business question : which products earned the most in the last quarter?
--  Access path      : date filter on customer_order, then order_line for those
--                     orders, then two dimension joins (variant -> product).
--                     ~52k of 440k order lines qualify.
--  Expected output  : 20 rows.
--
--  Grouping by p.product_id keeps the sort key narrow; name/brand are functional
--  dependencies of that key so they need no aggregation trickery.
-- =============================================================================
SELECT p.product_id,
       p.name                       AS product,
       b.name                       AS brand,
       SUM(l.quantity)              AS units_sold,
       SUM(l.line_total)            AS revenue
FROM customer_order o
JOIN order_line        l ON l.order_id   = o.order_id
JOIN product_variant   v ON v.variant_id = l.variant_id
JOIN product           p ON p.product_id = v.product_id
JOIN brand             b ON b.brand_id   = p.brand_id
WHERE o.order_date >= DATE '2026-10-20' - 90
  AND o.order_date <  DATE '2026-10-20'
  AND o.status IN ('paid', 'shipped', 'delivered', 'refunded')
GROUP BY p.product_id, p.name, b.name
ORDER BY revenue DESC
LIMIT 20;
