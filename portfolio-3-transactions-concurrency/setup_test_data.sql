-- Portfolio 3 test fixture.
--
-- The demonstrations need a product, a warehouse, a stock row and a customer that
-- they can create and destroy without touching the 1.35M seeded rows. Everything
-- below is identified by literal names, never by id, so the script is safe to run
-- repeatedly and works regardless of what the identity sequences have reached.
--
-- Run this before any of the transaction scripts; each one also includes it.
-- It does not set ON_ERROR_STOP itself: \i shares one session, so a setting here
-- would leak into a calling script that deliberately expects an error.

SET client_min_messages = warning;
SET TIME ZONE 'UTC';

BEGIN;

-- Tear down in dependency order. Order lines reference variants with ON DELETE
-- RESTRICT, so the test customer's orders have to go first.
--
-- The movements go before the orders on purpose. stock_movement.ref_order_id is
-- ON DELETE SET NULL, and ck_movement_sale_ref forbids a 'sale' movement without
-- an order reference, so deleting an order that a sale movement points at fails
-- unless the movement is removed first. That combination makes the ledger
-- effectively immutable: an order can never be deleted while it has sale
-- movements, which is the behaviour a ledger wants but the error message does
-- not explain. Recorded in README.md.
DELETE FROM stock_movement
 WHERE variant_id IN (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU');
DELETE FROM customer_order
 WHERE customer_id IN (SELECT customer_id FROM customer WHERE email = 'p3.tester@example.test');
DELETE FROM product_variant WHERE sku = 'P3-RACE-SKU';
DELETE FROM product       WHERE name = 'P3 concurrency test product';
DELETE FROM warehouse     WHERE name IN ('P3 test warehouse', 'P3 test warehouse 2');
DELETE FROM customer      WHERE email = 'p3.tester@example.test';
DELETE FROM brand         WHERE name = 'P3 test brand';

INSERT INTO brand (name) VALUES ('P3 test brand');

INSERT INTO product (name, description, brand_id)
SELECT 'P3 concurrency test product', 'Isolated fixture for the Portfolio 3 demonstrations', brand_id
FROM brand WHERE name = 'P3 test brand';

INSERT INTO product_variant (product_id, sku, price, weight_g)
SELECT product_id, 'P3-RACE-SKU', 25.00, 500
FROM product WHERE name = 'P3 concurrency test product';

INSERT INTO warehouse (name, city, country, region)
VALUES ('P3 test warehouse', 'Testville', 'GB', 'Test region'),
       ('P3 test warehouse 2', 'Testford', 'GB', 'Test region');

-- 10 units on hand: enough for the happy path, small enough that a lost update
-- is visible in one line of output.
INSERT INTO stock_level (variant_id, warehouse_id, quantity, reorder_point)
SELECT v.variant_id, w.warehouse_id, 10, 2
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU'
  AND w.name IN ('P3 test warehouse', 'P3 test warehouse 2');

INSERT INTO customer (email, first_name, last_name)
VALUES ('p3.tester@example.test', 'P3', 'Tester');

INSERT INTO customer_address (customer_id, line1, city, postcode, country, is_default)
SELECT customer_id, '1 Transaction Way', 'Testville', 'TE1 5T', 'GB', TRUE
FROM customer WHERE email = 'p3.tester@example.test';

COMMIT;

\echo 'fixture ready: P3-RACE-SKU with 10 units in each test warehouse, customer p3.tester@example.test'

SELECT v.sku, w.name AS warehouse, sl.quantity AS on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU'
ORDER BY w.name;
