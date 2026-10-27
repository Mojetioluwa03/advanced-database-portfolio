-- Session A of the safety-stock write skew: read the total, then take one unit
-- out of warehouse 1.
--
-- Business rule: at least one unit of P3-RACE-SKU must remain across the two
-- warehouses, so a sale is allowed only when the total is >= 2. Each session
-- checks the total and then updates a *different* row: no row is written by both,
-- so no row lock and no lost update - but together they break the rule. This is
-- write skew, and only SERIALIZABLE prevents it.
--
-- The isolation level arrives as -v iso="..." from 04_serializable.sh.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET default_transaction_isolation = :'iso';

\echo '[A] BEGIN at isolation level' :iso
BEGIN;
SHOW transaction_isolation;

\echo '[A] safety-stock check: total on hand across both warehouses'
SELECT sum(sl.quantity) AS total_on_hand
FROM stock_level sl
JOIN product_variant v USING (variant_id)
WHERE v.sku = 'P3-RACE-SKU';

SELECT (sum(sl.quantity) >= 2) AS a_can_sell
FROM stock_level sl
JOIN product_variant v USING (variant_id)
WHERE v.sku = 'P3-RACE-SKU' \gset

\echo '[A] rule: take one only if the total is >= 2, so can_sell =' :a_can_sell
\echo '[A] sleeping 1.5s so both sessions decide before either writes'
SELECT pg_sleep(1.5);

\if :a_can_sell
    \echo '[A] selling one unit from warehouse 1'
    UPDATE stock_level
       SET quantity = quantity - 1, updated_at = now()
     WHERE variant_id = (SELECT variant_id FROM product_variant WHERE sku = 'P3-RACE-SKU')
       AND warehouse_id = (SELECT warehouse_id FROM warehouse WHERE name = 'P3 test warehouse')
       AND quantity >= 1;

    INSERT INTO stock_movement (variant_id, warehouse_id, delta, reason, created_at)
    SELECT v.variant_id, w.warehouse_id, -1, 'adjustment', now()
    FROM product_variant v, warehouse w
    WHERE v.sku = 'P3-RACE-SKU' AND w.name = 'P3 test warehouse';

    \echo '[A] COMMIT'
    COMMIT;
\else
    \echo '[A] total < 2: refusing and rolling back'
    ROLLBACK;
\endif
