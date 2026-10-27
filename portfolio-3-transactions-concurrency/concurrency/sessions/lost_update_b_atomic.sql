-- Session B of the race, same guarded UPDATE, fired at ~2.4s.
--
-- A has committed by now, so the WHERE clause finds quantity = 0, matches no
-- row, and the checkout rolls back. No lock was taken explicitly and no stale
-- value was ever subtracted.

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

\echo '[B] validating the payment for 2s'
SELECT pg_sleep(2);

\echo '[B] UPDATE ... WHERE quantity >= 1 (no SELECT FOR UPDATE)'
WITH sold AS (
    UPDATE stock_level
       SET quantity = quantity - 1, updated_at = now()
     WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
       AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
       AND quantity >= 1
    RETURNING quantity
)
SELECT count(*) = 1 AS b_sold,
       coalesce(max(quantity), -1) AS b_qty_after
  FROM sold \gset

\if :b_sold
    INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, ref_order_id, created_at)
    SELECT v.variant_id, w.warehouse_id, -1, 'sale', :b_order_id, now()
    FROM product_variant v, warehouse w
    WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

    UPDATE customer_order SET status = 'paid' WHERE order_id = :b_order_id;
    \echo '[B] the guard matched; COMMIT - order' :b_order_id 'paid, on-hand now' :b_qty_after
    COMMIT;
\else
    \echo '[B] the guard matched no row: refusing the sale and rolling back'
    ROLLBACK;
    SELECT count(*) AS b_orders_remaining
      FROM customer_order WHERE order_id = :b_order_id;
\endif
