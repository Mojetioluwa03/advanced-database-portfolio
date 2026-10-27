-- 02 — a checkout that fails halfway: ROLLBACK leaves no trace.
--
-- Same six statements as 01. The payment leg fails (the provider declines, which
-- the constraint layer sees as an amount that violates ck_payment_amount). The
-- order, the order line and the stock decrement were already written — and they
-- must all disappear, because a checkout without payment is not a sale.
--
-- ON_ERROR_STOP is off on purpose: the point of the exercise is what the session
-- looks like *after* an error, before the ROLLBACK.
--
-- Run from portfolio-3-transactions-concurrency/:
--     psql -h localhost -p 5433 -U postgres -d shopstack -f transactions/02_checkout_rollback.sql

\i setup_test_data.sql
\set ON_ERROR_STOP off
SET TIME ZONE 'UTC';

\echo ''
\echo '=== BEFORE ==='
SELECT v.sku, w.name AS warehouse, sl.quantity AS on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

BEGIN;

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

UPDATE stock_level
   SET quantity = quantity - 2, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
   AND quantity >= 2;

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, ref_order_id, created_at)
SELECT v.variant_id, w.warehouse_id, -2, 'sale', :order_id, now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

\echo ''
\echo '--- order, line and stock are written; now the payment leg fails ---'
INSERT INTO payment (order_id, provider, method, amount, status, provider_ref, created_at)
VALUES (:order_id, 'stripe', 'card', -50.00, 'paid', 'pi_p3_declined_02', now());

-- After an error PostgreSQL refuses every further statement in the transaction
-- (SQLSTATE 25P02) until it is ended. This SELECT is here to show that:
\echo '--- any statement now fails with 25P02 until the transaction ends ---'
SELECT 'this would have run before the error' AS unreachable;

\echo ''
\echo '--- ROLLBACK ---'
ROLLBACK;

\echo ''
\echo '=== AFTER ROLLBACK: nothing the failed checkout wrote survives ==='
SELECT v.sku, w.name AS warehouse, sl.quantity AS on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

SELECT count(*) AS orders_placed
FROM customer_order
WHERE customer_id = (SELECT customer_id FROM customer WHERE email = 'p3.tester@example.test');

SELECT count(*) AS sale_movements,
       coalesce(sum(delta), 0) AS units_moved
FROM stock_movement m
JOIN product_variant v USING (variant_id)
WHERE v.sku = 'P3-RACE-SKU' AND m.reason = 'sale';

SELECT count(*) AS payments
FROM payment p
JOIN customer_order o USING (order_id)
WHERE o.customer_id IN (SELECT customer_id FROM customer WHERE email = 'p3.tester@example.test');

-- What to look for:
--   one ERROR line from the payment insert, one 25P02 line from the SELECT after
--   it, and then stock back at 10 with zero orders, zero movements and zero
--   payments. The failure left the database exactly as it found it.
