-- 01 — a complete checkout: COMMIT makes the whole unit durable.
--
-- The business transaction is one purchase: create the order, price the line,
-- take the units out of stock, record why the stock moved, take the payment and
-- mark the order paid. Either all six statements happen or none of them do.
--
-- Run from portfolio-3-transactions-concurrency/:
--     psql -h localhost -p 5433 -U postgres -d shopstack -f transactions/01_checkout_commit.sql

\set ON_ERROR_STOP on
\i setup_test_data.sql
SET TIME ZONE 'UTC';

\echo ''
\echo '=== BEFORE: stock on hand and this customer''s order count ==='
SELECT v.sku, w.name AS warehouse, sl.quantity AS on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

SELECT count(*) AS orders
FROM customer_order
WHERE customer_id = (SELECT customer_id FROM customer WHERE email = 'p3.tester@example.test');

BEGIN;
\echo ''
\echo '--- BEGIN: six statements, no COMMIT yet ---'

INSERT INTO customer_order (customer_id, order_date, status,
                            shipping_address_id, billing_address_id,
                            subtotal, grand_total)
SELECT c.customer_id, now(), 'pending', a.address_id, a.address_id, 50.00, 50.00
FROM customer c
JOIN customer_address a ON a.customer_id = c.customer_id AND a.is_default
WHERE c.email = 'p3.tester@example.test'
RETURNING order_id \gset

INSERT INTO order_line (order_id, variant_id, quantity, unit_price, line_total)
SELECT :order_id, variant_id, 2, price, 2 * price
FROM product_variant WHERE sku = 'P3-RACE-SKU';

-- The guard is part of the statement, not a separate check: if the row is no
-- longer there with 2 units, nothing is updated and the next statement sees it.
UPDATE stock_level
   SET quantity = quantity - 2, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
   AND quantity >= 2;

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, ref_order_id, created_at)
SELECT v.variant_id, w.warehouse_id, -2, 'sale', :order_id, now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

INSERT INTO payment (order_id, provider, method, amount, status, provider_ref, created_at)
VALUES (:order_id, 'stripe', 'card', 50.00, 'paid', 'pi_p3_commit_01', now());

UPDATE customer_order SET status = 'paid' WHERE order_id = :order_id;

\echo '--- inside the transaction, before COMMIT (visible to this session only) ---'
SELECT o.order_id, o.status, w.name AS warehouse, sl.quantity AS on_hand
FROM customer_order o
CROSS JOIN stock_level sl
JOIN product_variant v ON v.variant_id = sl.variant_id
JOIN warehouse w ON w.warehouse_id = sl.warehouse_id
WHERE o.order_id = :order_id AND v.sku = 'P3-RACE-SKU'
  AND w.name = 'P3 test warehouse';

COMMIT;
\echo '--- COMMIT ---'

\echo ''
\echo '=== AFTER: the same three questions, answered from committed state ==='
SELECT v.sku, w.name AS warehouse, sl.quantity AS on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

SELECT o.order_id, o.status, o.grand_total,
       l.quantity, l.unit_price, l.line_total,
       p.provider, p.status AS payment_status, p.amount,
       m.delta, m.reason
FROM customer_order o
JOIN order_line l      ON l.order_id = o.order_id
JOIN payment p         ON p.order_id = o.order_id
JOIN stock_movement m  ON m.ref_order_id = o.order_id AND m.reason = 'sale'
WHERE o.customer_id = (SELECT customer_id FROM customer WHERE email = 'p3.tester@example.test')
ORDER BY o.order_id;

-- What to look for:
--   stock 10 -> 8, one order in 'paid', one line of 2 units, one payment of 50.00,
--   and exactly one 'sale' movement of -2 pointing back at the order.
