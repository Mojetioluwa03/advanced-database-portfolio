-- =============================================================================
--  Q1 - Product page by SKU, relational form
--
--  Returns the same JSON document as queries/q1_product_page.js. Assembling it
--  takes eight relations - and category twice, once for the leaf and once for
--  its parent - plus a lateral pivot to turn the attribute/value rows back into
--  the map the page renders.
--
--  Every relation here is a read the aggregate model does not make: brand,
--  category (x2), attribute and attribute_value are embedded or flattened in
--  the document; product_variant and variant_attribute_value are inside it.
-- =============================================================================
WITH page AS (
    SELECT p.product_id
      FROM product p
     WHERE EXISTS (SELECT 1
                     FROM product_variant v
                    WHERE v.product_id = p.product_id
                      AND v.sku = 'SKU-00624-1')
)
SELECT jsonb_build_object(
           'product_id',  p.product_id,
           'name',        p.name,
           'description', p.description,
           'status',      p.status,
           'brand',       jsonb_build_object('brand_id', b.brand_id, 'name', b.name),
           'categories',  (SELECT jsonb_agg(jsonb_build_object(
                                              'category_id', c.category_id,
                                              'name',        c.name,
                                              'slug',        c.slug,
                                              'path',        jsonb_build_array(root.name, c.name)
                                          ) ORDER BY c.category_id)
                             FROM product_category pc
                             JOIN category c         ON c.category_id    = pc.category_id
                             LEFT JOIN category root ON root.category_id = c.parent_category_id
                            WHERE pc.product_id = p.product_id),
           'variants',    (SELECT jsonb_agg(jsonb_build_object(
                                              'variant_id', v.variant_id,
                                              'sku',        v.sku,
                                              'price',      v.price,
                                              'weight_g',   v.weight_g,
                                              'status',     v.status,
                                              'attributes', att.attributes
                                          ) ORDER BY v.variant_id)
                             FROM product_variant v
                             LEFT JOIN LATERAL (
                                    SELECT jsonb_object_agg(a.name, av.value) AS attributes
                                      FROM variant_attribute_value x
                                      JOIN attribute_value av ON av.value_id   = x.value_id
                                      JOIN attribute       a  ON a.attribute_id = av.attribute_id
                                     WHERE x.variant_id = v.variant_id
                             ) att ON TRUE
                            WHERE v.product_id = p.product_id)
       ) AS product
  FROM page
  JOIN product p ON p.product_id = page.product_id
  JOIN brand   b ON b.brand_id   = p.brand_id;
