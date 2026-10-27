-- =============================================================================
--  Q05 - Days of stock cover for warehouse 1
--
--  Business question : at the current sales rate, how long will each SKU in the
--                      Manchester warehouse last? Buyers use it to decide what
--                      to reorder this week.
--  Access path      : 90 days of sales from the stock_movement ledger (12k of
--                     424k rows) aggregated per variant, then joined to the
--                     on-hand balance for one warehouse (~7k rows).
--  Expected output  : 25 rows, shortest cover first.
--
--  Velocity is measured from the ledger rather than order_line so that returned
--  and adjusted stock is reflected; only 'sale' movements are counted.
-- =============================================================================
WITH velocity AS (
    SELECT m.variant_id,
           SUM(-m.delta) AS units_sold     -- sale deltas are negative
    FROM stock_movement m
    WHERE m.warehouse_id = 1
      AND m.reason = 'sale'
      AND m.created_at >= DATE '2026-10-20' - 90
      AND m.created_at <  DATE '2026-10-20'
    GROUP BY m.variant_id
)
SELECT v.sku,
       p.name                                   AS product,
       sl.quantity                              AS on_hand,
       COALESCE(vel.units_sold, 0)              AS units_sold_90d,
       ROUND(COALESCE(vel.units_sold, 0) / 90.0, 2) AS daily_rate,
       CASE WHEN COALESCE(vel.units_sold, 0) = 0 THEN NULL
            ELSE ROUND(sl.quantity / (vel.units_sold / 90.0), 0)
       END                                      AS days_of_cover
FROM stock_level sl
JOIN product_variant v ON v.variant_id = sl.variant_id
JOIN product         p ON p.product_id = v.product_id
LEFT JOIN velocity vel ON vel.variant_id = sl.variant_id
WHERE sl.warehouse_id = 1
ORDER BY days_of_cover NULLS LAST, v.sku
LIMIT 25;
