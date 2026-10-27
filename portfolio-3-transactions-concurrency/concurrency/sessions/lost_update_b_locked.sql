-- Session B with the fix: wait, then re-decide on the committed value.
--
-- The SELECT ... FOR UPDATE blocks until A commits, then returns 0 rather than
-- the stale 1 the naive version read. The application refuses the sale and rolls
-- back, so its order, line and stock movement never exist.

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
RETURNING order_id AS b_order_id \gset

INSERT INTO order_line (order_id, variant_id, quantity, unit_price, line_total)
SELECT :b_order_id, variant_id, 1, price, price
FROM product_variant WHERE sku = 'P3-RACE-SKU';

\echo '[B] order' :b_order_id 'created; SELECT ... FOR UPDATE - this waits for A'
SELECT quantity AS b_qty
  FROM stock_level
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
   FOR UPDATE
\gset

\echo '[B] unblocked; on-hand is now' :b_qty

-- psql's \if wants a boolean value, not a comparison, so the test is evaluated
-- by the server and stored with \gset.
SELECT (:b_qty::int < 1) AS b_refuse \gset
\if :b_refuse
    \echo '[B] not enough stock: refusing the sale and rolling back'
    ROLLBACK;
    SELECT count(*) AS b_orders_remaining
      FROM customer_order WHERE order_id = :b_order_id;
\else
    UPDATE stock_level
       SET quantity = :b_qty - 1, updated_at = now()
     WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
       AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse');

    INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, ref_order_id, created_at)
    SELECT v.variant_id, w.warehouse_id, -1, 'sale', :b_order_id, now()
    FROM product_variant v, warehouse w
    WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

    UPDATE customer_order SET status = 'paid' WHERE order_id = :b_order_id;
    \echo '[B] COMMIT - order' :b_order_id 'paid, one unit sold'
    COMMIT;
\endif
