-- Session A of the deadlock: lock the first warehouse, then the second.
--
-- The 2s pause is the window in which B can take the other lock. When A asks for
-- warehouse 2 it waits for B, and B is already waiting for A's warehouse 1: a
-- cycle, which PostgreSQL detects after deadlock_timeout and breaks by aborting
-- one of the two.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\echo '[A] BEGIN'
BEGIN;

\echo '[A] lock warehouse 1'
UPDATE stock_level
   SET quantity = quantity - 1, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
   AND quantity >= 1;

-- A ledger row after each movement, so the final ledger shows whether the
-- aborted transaction left anything behind.
INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, created_at)
SELECT v.variant_id, w.warehouse_id, -1, 'adjustment', now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

\echo '[A] holding warehouse 1; sleeping 2s'
SELECT pg_sleep(2);

\echo '[A] now lock warehouse 2'
UPDATE stock_level
   SET quantity = quantity - 1, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse 2')
   AND quantity >= 1;

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, created_at)
SELECT v.variant_id, w.warehouse_id, -1, 'adjustment', now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse 2';

\echo '[A] COMMIT - both rows updated'
COMMIT;
