-- =============================================================================
--  Q4 - Clearance sweep: every product with an active variant under GBP 20
--
--  Same rows as queries/q4_price_sweep.js.
--
--  This is the query the aggregate boundary makes awkward, and in SQL it is
--  simply a join predicate: product_variant is its own table, so filtering it
--  by price is free. The document model has to reach inside variants with
--  $elemMatch (for the filter) and $filter (to project only the cheap rows).
--
--  The price predicate is on the same row as the status predicate, which in
--  SQL is merely two conjuncts in one WHERE clause - the correlation the array
--  model has to be told about explicitly.
-- =============================================================================
SELECT p.product_id,
       p.name,
       b.name                                   AS brand,
       jsonb_agg(jsonb_build_object(
                     'sku',   v.sku,
                     'price', v.price
                 ) ORDER BY v.sku)              AS cheap_variants
  FROM product p
  JOIN brand           b ON b.brand_id  = p.brand_id
  JOIN product_variant v ON v.product_id = p.product_id
                         AND v.status    = 'active'
                         AND v.price     < 20
 WHERE p.status = 'active'
 GROUP BY p.product_id, p.name, b.name
 ORDER BY p.product_id
 LIMIT 200;
