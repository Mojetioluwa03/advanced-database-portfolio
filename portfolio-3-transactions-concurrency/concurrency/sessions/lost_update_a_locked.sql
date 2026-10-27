-- Session A with the fix: lock the stock row before deciding.
--
-- SELECT ... FOR UPDATE waits for any other transaction holding the same row and,
-- once it gets the lock, returns the row as it is *after* that transaction
-- committed. The decision is therefore made on current data.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\echo '[A] BEGIN'
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
RETURNING order_id AS a_order_id \gset

INSERT INTO order_line (order_id, variant_id, quantity, unit_price, line_total)
SELECT :a_order_id, variant_id, 1, price, price
FROM product_variant WHERE sku = 'P3-RACE-SKU';

\echo '[A] SELECT ... FOR UPDATE (takes the row lock)'
SELECT quantity AS a_qty
  FROM stock_level
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
   FOR UPDATE
\gset
\echo '[A] order' :a_order_id 'created; locked and read on-hand =' :a_qty

\echo '[A] validating the payment for 2s'
SELECT pg_sleep(2);

UPDATE stock_level
   SET quantity = :a_qty - 1, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse');

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, ref_order_id, created_at)
SELECT v.variant_id, w.warehouse_id, -1, 'sale', :a_order_id, now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

UPDATE customer_order SET status = 'paid' WHERE order_id = :a_order_id;

\echo '[A] COMMIT - order' :a_order_id 'paid, one unit sold'
COMMIT;
