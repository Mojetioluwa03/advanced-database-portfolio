-- Writer session: restocks four units and appends the matching ledger row, in
-- one quick transaction that starts 0.4s after the observer.
--
-- It does not care about the observer's level: it just commits. What the
-- observer sees afterwards is the entire point.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\echo '[B] BEGIN'
BEGIN;

UPDATE stock_level
   SET quantity = quantity + 4, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse');

INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, created_at)
SELECT v.variant_id, w.warehouse_id, 4, 'restock', now()
FROM product_variant v, warehouse w
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

\echo '[B] restocked 4 units; own uncommitted view:'
SELECT sl.quantity AS on_hand,
       (SELECT count(*) FROM stock_movement m WHERE m.variant_id = v.variant_id) AS movements
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

\echo '[B] COMMIT'
COMMIT;
