-- =============================================================================
--  Q08 - Carrier delivery performance, last 12 months
--
--  Business question : which carrier delivers fastest, and what share of its
--                      parcels arrive within the promised 5 days?
--  Access path      : 149k delivered shipments, filtered by status and dispatch
--                     date, aggregated into 5 carriers.
--  Expected output  : 5 rows.
--
--  "Delivered" is 90% of the shipment table, so a plain index on status is
--  useless here; the useful index is a covering one that holds only delivered
--  rows and the three date columns the aggregate needs.
-- =============================================================================
SELECT s.carrier,
       COUNT(*)                                    AS delivered_shipments,
       ROUND(AVG(EXTRACT(EPOCH FROM (s.delivered_at - s.dispatched_at)) / 86400.0), 2)
                                                   AS avg_days_in_transit,
       COUNT(*) FILTER (WHERE s.delivered_at - s.dispatched_at <= INTERVAL '5 days')
                                                   AS on_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.delivered_at - s.dispatched_at <= INTERVAL '5 days')
             / COUNT(*), 1)                        AS on_time_pct
FROM shipment s
WHERE s.status = 'delivered'
  AND s.dispatched_at >= DATE '2025-10-20'
GROUP BY s.carrier
ORDER BY on_time_pct DESC, s.carrier;
