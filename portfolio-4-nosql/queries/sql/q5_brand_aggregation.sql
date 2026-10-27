-- =============================================================================
--  Q5 - Brand league table: products and price spread per brand, top 10
--
--  Same rows as queries/q5_brand_aggregation.js.
--
--  Neither engine can answer this from an index - both scan and hash-aggregate.
--  The difference is the join: SQL joins brand purely to resolve a name, which
--  is 10,000 lookups against a 40-row table. The document model paid for that
--  with 80 bytes of brand name in every product document instead, at load time
--  and again on every rename.
--
--  AVG(v.price) is NUMERIC here and double in the document model; the rounding
--  to 2dp makes the outputs comparable.
-- =============================================================================
SELECT b.brand_id,
       b.name                       AS brand,
       COUNT(DISTINCT p.product_id) AS products,
       COUNT(*)                     AS variants,
       MIN(v.price)                 AS min_price,
       MAX(v.price)                 AS max_price,
       ROUND(AVG(v.price), 2)       AS avg_price
  FROM product p
  JOIN brand           b ON b.brand_id  = p.brand_id
  JOIN product_variant v ON v.product_id = p.product_id
                         AND v.status    = 'active'
 WHERE p.status = 'active'
 GROUP BY b.brand_id, b.name
 ORDER BY products DESC, brand
 LIMIT 10;
