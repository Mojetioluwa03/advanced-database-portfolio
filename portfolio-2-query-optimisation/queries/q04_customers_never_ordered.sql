-- =============================================================================
--  Q04 - Active customers who have never placed an order
--
--  Business question : which registered, active accounts have never converted?
--                      Target list for the win-back campaign.
--  Access path      : anti-join (NOT EXISTS) from 46,517 active customers
--                     against 200k orders.
--  Expected output  : 883 rows.
--
--  NOT EXISTS rather than NOT IN: NOT IN silently returns nothing if the inner
--  column ever contains NULL, and it cannot use an anti-join plan.
-- =============================================================================
SELECT c.customer_id,
       c.email,
       c.first_name || ' ' || c.last_name AS full_name,
       c.created_at::date                  AS signed_up
FROM customer c
WHERE c.status = 'active'
  AND NOT EXISTS (
      SELECT 1 FROM customer_order o WHERE o.customer_id = c.customer_id
  )
ORDER BY c.created_at;
