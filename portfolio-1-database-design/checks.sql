-- =============================================================================
--  MIT 8103 Advanced Database Systems - Portfolio 1
--  Post-load verification. Every check below should report 0 for the failure
--  columns; the row counts are the evidence recorded in the README.
--
--      psql -d shopstack -f checks.sql
-- =============================================================================

\echo '=== 1. Row counts ==='
SELECT 'brand'                   AS table_name, COUNT(*) FROM brand
UNION ALL SELECT 'category',                COUNT(*) FROM category
UNION ALL SELECT 'supplier',                COUNT(*) FROM supplier
UNION ALL SELECT 'product',                 COUNT(*) FROM product
UNION ALL SELECT 'product_category',        COUNT(*) FROM product_category
UNION ALL SELECT 'product_variant',         COUNT(*) FROM product_variant
UNION ALL SELECT 'variant_attribute_value', COUNT(*) FROM variant_attribute_value
UNION ALL SELECT 'customer',                COUNT(*) FROM customer
UNION ALL SELECT 'customer_address',        COUNT(*) FROM customer_address
UNION ALL SELECT 'warehouse',               COUNT(*) FROM warehouse
UNION ALL SELECT 'stock_level',             COUNT(*) FROM stock_level
UNION ALL SELECT 'stock_movement',          COUNT(*) FROM stock_movement
UNION ALL SELECT 'cart',                    COUNT(*) FROM cart
UNION ALL SELECT 'promotion',               COUNT(*) FROM promotion
UNION ALL SELECT 'customer_order',          COUNT(*) FROM customer_order
UNION ALL SELECT 'order_line',              COUNT(*) FROM order_line
UNION ALL SELECT 'payment',                 COUNT(*) FROM payment
UNION ALL SELECT 'shipment',                COUNT(*) FROM shipment
UNION ALL SELECT 'review',                  COUNT(*) FROM review
UNION ALL SELECT 'return_request',          COUNT(*) FROM return_request
ORDER BY table_name;


\echo '=== 2. Order totals must reconcile with their lines (expect 0) ==='
SELECT COUNT(*) AS orders_with_wrong_totals
FROM v_order_reconciliation
WHERE subtotal <> recomputed_subtotal
   OR grand_total <> recomputed_grand_total;

\echo '=== 3. Settled orders must have a payment equal to grand_total (expect 0) ==='
SELECT COUNT(*) AS orders_with_payment_mismatch
FROM customer_order o
JOIN LATERAL (
    SELECT COALESCE(SUM(amount), 0) AS paid
    FROM payment p
    WHERE p.order_id = o.order_id
      AND p.status IN ('paid', 'refunded')
) x ON TRUE
WHERE o.status IN ('paid', 'shipped', 'delivered', 'refunded')
  AND x.paid <> o.grand_total;

\echo '=== 4. stock_level must equal the sum of its movement ledger (expect 0) ==='
WITH ledger AS (
    SELECT variant_id, warehouse_id, SUM(delta) AS ledger_quantity
    FROM stock_movement
    GROUP BY variant_id, warehouse_id
)
SELECT COUNT(*) AS mismatched_stock_rows
FROM stock_level sl
LEFT JOIN ledger l USING (variant_id, warehouse_id)
WHERE sl.quantity <> COALESCE(l.ledger_quantity, 0);

\echo '=== 5. No negative stock (expect 0) ==='
SELECT COUNT(*) AS negative_stock_rows FROM stock_level WHERE quantity < 0;

\echo '=== 6. At most one default address per customer (expect 0) ==='
SELECT COUNT(*) AS customers_with_multiple_defaults
FROM (
    SELECT customer_id
    FROM customer_address
    WHERE is_default
    GROUP BY customer_id
    HAVING COUNT(*) > 1
) d;

\echo '=== 7. Categories never reference themselves (expect 0) ==='
SELECT COUNT(*) AS self_parent_categories
FROM category
WHERE parent_category_id = category_id;

\echo '=== 8. Orders per month (distribution sanity check) ==='
SELECT date_trunc('month', order_date)::date AS month,
       COUNT(*)                              AS orders,
       ROUND(SUM(grand_total), 2)            AS revenue
FROM customer_order
GROUP BY 1
ORDER BY 1;

\echo '=== 9. Order status mix ==='
SELECT status,
       COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM customer_order
GROUP BY status
ORDER BY orders DESC;

\echo '=== 10. Catalogue depth: products per root category ==='
WITH RECURSIVE tree AS (
    SELECT category_id, category_id AS root_id, name
    FROM category
    WHERE parent_category_id IS NULL
    UNION ALL
    SELECT c.category_id, t.root_id, c.name
    FROM category c
    JOIN tree t ON c.parent_category_id = t.category_id
)
SELECT r.name                            AS root_category,
       COUNT(DISTINCT pc.product_id)     AS products
FROM tree r
JOIN tree t   ON t.root_id = r.category_id
JOIN product_category pc ON pc.category_id = t.category_id
GROUP BY r.name
ORDER BY products DESC;
