-- =============================================================================
--  Q2 - Category browse: one leaf category, price band, cheapest first
--
--  Same rows and columns as queries/q2_category_browse.js. Note where the price
--  band lands: in the document model it is a $set over each document's variants
--  and then a $match on the computed minimum; here it is HAVING over a grouped
--  join. Both need the group before they can filter, so both pay for a sort of
--  the 76 qualifying products.
--
--  The category filter is a plain equality on category.slug, which is exactly
--  the column a B-tree index would carry. MongoDB can only index the same
--  access path as a multikey index, and cannot extend it with variants.price.
-- =============================================================================
SELECT p.product_id,
       p.name,
       b.name                       AS brand,
       MIN(v.price)                 AS from_price,
       COUNT(*)                     AS buyable,
       (SELECT jsonb_agg(jsonb_build_object(
                          'category_id', c2.category_id,
                          'name',        c2.name,
                          'slug',        c2.slug)
                        ORDER BY c2.category_id)
          FROM product_category pc2
          JOIN category c2 ON c2.category_id = pc2.category_id
         WHERE pc2.product_id = p.product_id) AS categories
  FROM product p
  JOIN brand            b  ON b.brand_id    = p.brand_id
  JOIN product_category pc ON pc.product_id = p.product_id
  JOIN category         c  ON c.category_id = pc.category_id
  JOIN product_variant  v  ON v.product_id  = p.product_id
                          AND v.status      = 'active'
 WHERE c.slug    = 'electronics-audio'
   AND p.status  = 'active'
 GROUP BY p.product_id, p.name, b.name
HAVING MIN(v.price) BETWEEN 20 AND 200
 ORDER BY from_price, p.product_id
 LIMIT 20;
