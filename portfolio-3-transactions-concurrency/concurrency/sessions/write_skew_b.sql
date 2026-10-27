-- Session B of the safety-stock write skew: same check, different row.
--
-- It takes its unit out of warehouse 2. Under REPEATABLE READ its snapshot
-- predates A's commit, so it still sees a total of 2 and commits: the rule is
-- broken and neither transaction was ever blocked. Under SERIALIZABLE the
-- read/write dependency between the two is detected and this commit fails with
-- SQLSTATE 40001, which the caller retries.
--
-- The isolation level arrives as -v iso="..." from 04_serializable.sh.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET default_transaction_isolation = :'iso';

\echo '[B] BEGIN at isolation level' :iso
BEGIN;
SHOW transaction_isolation;

\echo '[B] safety-stock check: total on hand across both warehouses'
SELECT sum(sl.quantity) AS total_on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
WHERE v.sku = 'P3-RACE-SKU';

SELECT (sum(sl.quantity) >= 2) AS b_can_sell
FROM stock_level sl
JOIN product_variant v USING (variant_id)
WHERE v.sku = 'P3-RACE-SKU' \gset

\echo '[B] rule: take one only if the total is >= 2, so can_sell =' :b_can_sell
\echo '[B] sleeping 1.5s so both sessions decide before either writes'
SELECT pg_sleep(1.5);

\if :b_can_sell
    \echo '[B] selling one unit from warehouse 2'
    UPDATE stock_level
       SET quantity = quantity - 1, updated_at = now()
     WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
       AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse 2')
       AND quantity >= 1;

    INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, created_at)
    SELECT v.variant_id, w.warehouse_id, -1, 'adjustment', now()
    FROM product_variant v, warehouse w
    WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse 2';

    \echo '[B] COMMIT'
    COMMIT;
\else
    \echo '[B] total < 2: refusing and rolling back'
    ROLLBACK;
\endif
