-- Session B of the deadlock: the same two rows, opposite order.
--
-- This is the classic lock-ordering mistake. Neither session can finish, so the
-- deadlock detector picks one as the victim and fails it with SQLSTATE 40P01;
-- the survivor's blocked statement then proceeds.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\echo '[B] BEGIN'
BEGIN;

\echo '[B] lock warehouse 2'
UPDATE stock_level
   SET quantity = quantity - 1, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse 2')
   AND quantity >= 1;

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, created_at)
SELECT v.variant_id, w.warehouse_id, -1, 'adjustment', now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse 2';

\echo '[B] holding warehouse 2; sleeping 2s'
SELECT pg_sleep(2);

\echo '[B] now lock warehouse 1'
UPDATE stock_level
   SET quantity = quantity - 1, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
   AND quantity >= 1;

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, created_at)
SELECT v.variant_id, w.warehouse_id, -1, 'adjustment', now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

\echo '[B] COMMIT - both rows updated'
COMMIT;
