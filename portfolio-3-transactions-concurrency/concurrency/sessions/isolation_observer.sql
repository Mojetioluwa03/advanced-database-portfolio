-- Observer session: asks the same two questions three times inside one
-- transaction while another session changes the data in between.
--
-- The isolation level arrives as a psql variable, -v iso="read committed" or
-- -v iso="repeatable read", so the same script runs at both levels and the
-- difference is purely the level, not the code. It is applied through
-- default_transaction_isolation because SET TRANSACTION ISOLATION LEVEL takes
-- keywords, not a string expression. SHOW proves what the transaction got.
--
-- The two questions are deliberately different shapes:
--   * on_hand     - an existing row whose value changes  (non-repeatable read)
--   * movements   - a set that gains a row                (phantom read)

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET default_transaction_isolation = :'iso';

\echo '[A] BEGIN at isolation level' :iso
BEGIN;
SHOW transaction_isolation;

\echo '[A] read 1 - before B commits'
SELECT sl.quantity AS on_hand,
       (SELECT count(*) FROM stock_movement m WHERE m.variant_id = v.variant_id) AS movements
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

\echo '[A] sleeping 2s - B restocks and commits in this window'
SELECT pg_sleep(2);

\echo '[A] read 2 - same transaction, B has committed'
SELECT sl.quantity AS on_hand,
       (SELECT count(*) FROM stock_movement m WHERE m.variant_id = v.variant_id) AS movements
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

SELECT pg_sleep(1);

\echo '[A] read 3 - 1s later, still the same transaction'
SELECT sl.quantity AS on_hand,
       (SELECT count(*) FROM stock_movement m WHERE m.variant_id = v.variant_id) AS movements
FROM stock_level sl
JOIN product_variant v USING (variant_id)
JOIN warehouse w USING (warehouse_id)
WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

COMMIT;
