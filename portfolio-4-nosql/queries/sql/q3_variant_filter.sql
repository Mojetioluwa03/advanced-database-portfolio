-- =============================================================================
--  Q3 - Variant attribute filter: Black AND 256GB, on the same variant
--
--  Same rows as queries/q3_variant_filter.js. The point of the comparison is
--  how differently the "same variant" requirement is expressed.
--
--  Here both EXISTS subqueries are correlated on v.variant_id, so there is no
--  scope for the two conditions to drift onto different variants: the row being
--  tested is one physical variant. That is a property of the join, not of the
--  author. In the document model the array is the row, and a filter written as
--  two dotted paths silently loses the correlation - see experiments/
--  q3_elem_match_trap.js.
--
--  What the relational form pays for that clarity is the attribute model: name
--  and value live in three tables, so each predicate is a two-hop join, and
--  rendering the attributes as a map needs the LATERAL pivot.
-- =============================================================================
SELECT p.product_id,
       p.name,
       b.name                                   AS brand,
       jsonb_agg(jsonb_build_object(
                     'sku',        v.sku,
                     'price',      v.price,
                     'attributes', att.attributes
                 ) ORDER BY v.sku)              AS matched_variants
  FROM product p
  JOIN brand            b  ON b.brand_id    = p.brand_id
  JOIN product_category pc ON pc.product_id = p.product_id
  JOIN category         c  ON c.category_id = pc.category_id
  JOIN product_variant  v  ON v.product_id  = p.product_id
                          AND v.status      = 'active'
  LEFT JOIN LATERAL (
        SELECT jsonb_object_agg(a.name, av.value) AS attributes
          FROM variant_attribute_value x
          JOIN attribute_value av ON av.value_id    = x.value_id
          JOIN attribute       a  ON a.attribute_id = av.attribute_id
         WHERE x.variant_id = v.variant_id
  ) att ON TRUE
 WHERE c.slug   = 'electronics-phones'
   AND p.status = 'active'
   AND EXISTS (SELECT 1
                 FROM variant_attribute_value x
                 JOIN attribute_value av ON av.value_id    = x.value_id
                 JOIN attribute       a  ON a.attribute_id = av.attribute_id
                WHERE x.variant_id = v.variant_id
                  AND a.name       = 'colour'
                  AND av.value     = 'Black')
   AND EXISTS (SELECT 1
                 FROM variant_attribute_value x
                 JOIN attribute_value av ON av.value_id    = x.value_id
                 JOIN attribute       a  ON a.attribute_id = av.attribute_id
                WHERE x.variant_id = v.variant_id
                  AND a.name       = 'capacity'
                  AND av.value     = '256GB')
 GROUP BY p.product_id, p.name, b.name
 ORDER BY p.name;
