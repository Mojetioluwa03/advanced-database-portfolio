-- Session B of the oversell race: the same code, started 0.4s later.
--
-- A has already written 0 back to the row but has not committed, so at READ
-- COMMITTED this session's plain SELECT still sees the last committed value, 1.
-- Both sessions therefore write "their" 1 - 1 = 0 back, and the second write
-- erases the first without any error being raised.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\echo '[B] BEGIN (0.4s after A)'
BEGIN;

INSERT INTO customer_order (customer_id, order_date, status,
                            shipping_address_id, billing_address_id,
                            subtotal, grand_total)
SELECT c.customer_id, now(), 'pending', a.address_id, a.address_id,
       v.price, v.price
FROM customer c
JOIN customer_address a ON a.customer_id = c.customer_id AND a.is_default
CROSS JOIN product_variant v
WHERE c.email = 'p3.tester@example.test' AND v.sku = 'P3-RACE-SKU'
RETURNING order_id \gset

INSERT INTO order_line (order_id, variant_id, quantity, unit_price, line_total)
SELECT :order_id, variant_id, 1, price, price
FROM product_variant WHERE sku = 'P3-RACE-SKU';

SELECT quantity AS b_qty
  FROM stock_level
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
\gset
\echo '[B] order' :order_id 'created; read on-hand =' :b_qty '(A has not committed yet)'

\echo '[B] validating the payment for 2.4s'
SELECT pg_sleep(2.4);

\echo '[B] writing back' :b_qty '- 1'
UPDATE stock_level
   SET quantity = :b_qty - 1, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse');

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, ref_order_id, created_at)
SELECT v.variant_id, w.warehouse_id, -1, 'sale', :order_id, now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

UPDATE customer_order SET status = 'paid' WHERE order_id = :order_id;

\echo '[B] COMMIT - order' :order_id 'paid, one unit sold'
COMMIT;
