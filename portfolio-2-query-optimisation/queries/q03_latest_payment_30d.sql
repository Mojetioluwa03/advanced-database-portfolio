-- =============================================================================
--  Q03 - Settlement check: latest payment attempt for every recent order
--
--  Business question : for each order in the last 30 days, what was the most
--                      recent payment attempt and did it succeed? Used by
--                      finance to chase orders that are paid/shipped in the
--                      order table but have no successful payment behind them.
--  Access path      : "latest row per group". Written as LATERAL + LIMIT 1
--                     because that is the natural SQL form; it forces one
--                     payment lookup per qualifying order.
--  Expected output  : ~8k rows (one per order in the window).
--
--  This is the query that exposes the missing index on payment.order_id. Without
--  it the inner scan is a full sequential scan of 181k payments per outer order.
-- =============================================================================
SELECT o.order_id,
       o.order_date::date  AS order_day,
       o.status            AS order_status,
       o.grand_total,
       pay.provider,
       pay.method,
       pay.status          AS latest_payment_status,
       pay.amount          AS latest_payment_amount,
       pay.created_at      AS latest_payment_at
FROM customer_order o
LEFT JOIN LATERAL (
    SELECT p.provider, p.method, p.status, p.amount, p.created_at
    FROM payment p
    WHERE p.order_id = o.order_id
    ORDER BY p.created_at DESC, p.payment_id DESC
    LIMIT 1
) pay ON TRUE
WHERE o.order_date >= DATE '2026-10-20' - 30
  AND o.order_date <  DATE '2026-10-20'
ORDER BY o.order_id;
