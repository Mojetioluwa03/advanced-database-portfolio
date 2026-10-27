-- 03 — a checkout that fails halfway but must not lose the first half: SAVEPOINT.
--
-- Real carts survive a declined card. The order should stay open with the stock
-- reserved, so the customer can retry with another card, and the failed attempt
-- should be recorded for support. A plain ROLLBACK would throw the reservation
-- away; a SAVEPOINT before the payment leg unwinds only that leg.
--
-- Run from portfolio-3-transactions-concurrency/:
--     psql -h localhost -p 5433 -U postgres -d shopstack -f transactions/03_savepoint_partial_failure.sql

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

-- Everything above is the part we want to keep.
SAVEPOINT before_payment;
\echo ''
\echo '--- SAVEPOINT before_payment: the first card is declined ---'

INSERT INTO payment (order_id, provider, method, amount, status, provider_ref, created_at)
VALUES (:order_id, 'stripe', 'card', -50.00, 'paid', 'pi_p3_declined_03', now());

\echo ''
\echo '--- ROLLBACK TO SAVEPOINT: undo the failed charge only ---'
ROLLBACK TO SAVEPOINT before_payment;

INSERT INTO payment (order_id, provider, method, amount, status, provider_ref, created_at)
VALUES (:order_id, 'stripe', 'card', 50.00, 'failed', 'pi_p3_declined_03', now());

-- The order stays 'pending': the money was never taken, so it is not paid, but
-- the reservation and the order itself are real and must survive the COMMIT.
UPDATE customer_order SET status = 'pending' WHERE order_id = :order_id;

COMMIT;
\echo ''
\echo '--- COMMIT ---'

\echo ''
\echo '=== AFTER: the reservation survived, the charge did not ==='
SELECT v.sku, w.name AS warehouse, sl.quantity AS on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

SELECT o.order_id, o.status,
       l.quantity, l.line_total,
       p.status AS payment_status, p.amount, p.provider_ref
FROM customer_order o
JOIN order_line l ON l.order_id = o.order_id
JOIN payment p    ON p.order_id = o.order_id
WHERE o.customer_id = (SELECT customer_id FROM customer WHERE email = 'p3.tester@example.test')
ORDER BY p.payment_id;

SELECT count(*) AS sale_movements
FROM stock_movement m
JOIN product_variant v USING (variant_id)
WHERE v.sku = 'P3-RACE-SKU' AND m.reason = 'sale';

-- What to look for:
--   one ERROR line for the declined charge, then a committed order in 'pending'
--   with its line, stock at 8, the 'sale' movement still recorded, and exactly
--   one payment row - the 'failed' one. The successful charge is the only thing
--   that was undone, which is precisely the difference between ROLLBACK and
--   ROLLBACK TO SAVEPOINT.
