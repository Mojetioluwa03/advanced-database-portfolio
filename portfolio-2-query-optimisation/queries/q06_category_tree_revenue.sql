-- =============================================================================
--  Q06 - Revenue by top-level category (whole catalogue history)
--
--  Business question : which part of the catalogue actually earns? Categories
--                      form a two-level tree, so revenue has to be rolled up
--                      from leaf categories to their root.
--  Access path      : recursive CTE to map each of the 40 categories to its
--                     root, then a product -> variant -> order_line join.
--  Expected output  : 8 rows (one per root category).
--
--  About 1,000 products are cross-listed in a second category. DISTINCT on
--  (product_id, root_id) counts a product once per root it belongs to, so
--  revenue is not double counted inside a root.
-- =============================================================================
WITH RECURSIVE tree AS (
    SELECT c.category_id,
           c.category_id AS root_id
    FROM category c
    WHERE c.parent_category_id IS NULL
    UNION ALL
    SELECT c.category_id,
           t.root_id
    FROM category c
    JOIN tree t ON t.category_id = c.parent_category_id
),
product_root AS (
    SELECT DISTINCT pc.product_id,
                    t.root_id
    FROM product_category pc
    JOIN tree t ON t.category_id = pc.category_id
)
SELECT root.name              AS root_category,
       COUNT(DISTINCT pr.product_id) AS products,
       SUM(l.quantity)        AS units_sold,
       SUM(l.line_total)      AS revenue
FROM product_root   pr
JOIN category       root ON root.category_id = pr.root_id
JOIN product_variant v   ON v.product_id     = pr.product_id
JOIN order_line     l    ON l.variant_id     = v.variant_id
GROUP BY pr.root_id, root.name
ORDER BY revenue DESC;
