-- Session A of the race, fixed without an explicit lock: one guarded UPDATE.
--
-- The decision "is there still a unit?" moves into the UPDATE's WHERE clause, so
-- the database evaluates it against the current row version while it holds the
-- write lock. The SELECT is here only to show what the application would have
-- read; it is not used for the decision.

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

\echo '[A] validating the payment for 2s'
SELECT pg_sleep(2);

\echo '[A] UPDATE ... WHERE quantity >= 1 (no SELECT FOR UPDATE)'
-- The UPDATE sits in a CTE so the row count can be captured as a boolean: psql's
-- \gset refuses a query that returns no rows, and "the guard matched nothing" is
-- exactly the case that must be handled.
WITH sold AS (
    UPDATE stock_level
       SET quantity = quantity - 1, updated_at = now()
     WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
       AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
       AND quantity >= 1
    RETURNING quantity
)
SELECT count(*) = 1 AS a_sold,
       coalesce(max(quantity), -1) AS a_qty_after
  FROM sold \gset

\if :a_sold
    INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, ref_order_id, created_at)
    SELECT v.variant_id, w.warehouse_id, -1, 'sale', :a_order_id, now()
    FROM product_variant v, warehouse w
    WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

    UPDATE customer_order SET status = 'paid' WHERE order_id = :a_order_id;
    \echo '[A] the guard matched; COMMIT - order' :a_order_id 'paid, on-hand now' :a_qty_after
    COMMIT;
\else
    \echo '[A] the guard matched no row - rolling back'
    ROLLBACK;
\endif
