-- Reader that asks for READ UNCOMMITTED, the one level that would be allowed to
-- see a dirty read if the server implemented it.
--
-- It waits 1.2s, so its read lands while dirty_writer's 999 is written but not
-- committed. PostgreSQL answers 1: there are no dirty reads at any level, and
-- READ UNCOMMITTED is accepted only as an alias for READ COMMITTED.
--
-- The isolation level arrives as -v iso="..." from 02_isolation_levels.sh.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET default_transaction_isolation = :'iso';

\echo '[A] BEGIN at isolation level' :iso
BEGIN;
SHOW transaction_isolation;

\echo '[A] waiting 1.2s so B has written 999 before this read'
SELECT pg_sleep(1.2);

\echo '[A] read while 999 is written but uncommitted'
SELECT sl.quantity AS on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

COMMIT;
