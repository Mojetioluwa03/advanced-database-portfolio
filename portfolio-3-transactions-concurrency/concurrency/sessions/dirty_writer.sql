-- Writer that never commits: sets an absurd on-hand value and leaves it
-- uncommitted for 3s, then rolls back.
--
-- Nothing may ever read the 999. If a reader sees it, that is a dirty read.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\echo '[B] BEGIN - a change nobody should see yet'
BEGIN;

UPDATE stock_level
   SET quantity = 999, updated_at = now()
 WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
   AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse');

\echo '[B] on-hand is 999 inside this transaction, held uncommitted for 3s'
SELECT pg_sleep(3);

\echo '[B] ROLLBACK - the 999 never existed'
ROLLBACK;
