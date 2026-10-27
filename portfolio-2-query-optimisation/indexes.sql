-- =============================================================================
--  Portfolio 2 - secondary indexes
--
--  schema.sql ships with primary-key and unique indexes only, so the plans in
--  plans/before/ are a true unindexed baseline. Every index below exists
--  because one query in queries/ needs it; the comment names that query and the
--  access pattern it serves. Indexes that were tried and rejected are in
--  experiments/ rather than here.
--
--      psql -d shopstack -f indexes.sql
--      psql -d shopstack -f drop_indexes.sql     -- back to the baseline
--
--  Column order follows the rule "equality predicates first, then range, then
--  the columns only needed for output (INCLUDE)".
-- =============================================================================

BEGIN;

-- q01 - 30-day trading report.
-- Range scan on order_date; the report also reads status and grand_total, so
-- they ride along in the leaf pages and the plan can be an index-only scan.
CREATE INDEX IF NOT EXISTS ix_order_date
    ON customer_order (order_date) INCLUDE (status, grand_total);

-- q03 - latest payment attempt per order.
-- Equality on order_id, then a backward walk of created_at to satisfy
-- ORDER BY ... LIMIT 1. payment_id is the tie-breaker in that ORDER BY.
-- Deliberately narrow: LIMIT 1 costs one heap fetch per order anyway, so
-- covering the other payment columns would only make the index fatter.
CREATE INDEX IF NOT EXISTS ix_payment_order_recent
    ON payment (order_id, created_at DESC) INCLUDE (payment_id);

-- q04 - active customers with no orders (anti-join probe on customer_id).
-- q07 - lifetime spend per customer (group by customer_id, filter on status,
--       sum grand_total; order_date is needed for first/last order).
-- One index serves both because both are keyed on customer_id.
CREATE INDEX IF NOT EXISTS ix_order_customer
    ON customer_order (customer_id) INCLUDE (status, grand_total, order_date);

-- q02 - revenue roll-up from products into order lines.
-- q06 - same walk for the category report.
-- Also the missing index for the order_line.variant_id foreign key: without it
-- deleting or re-keying one variant scans all 440k lines to enforce RESTRICT.
CREATE INDEX IF NOT EXISTS ix_order_line_variant
    ON order_line (variant_id) INCLUDE (line_total, quantity);

-- q05 - 90 days of sales for one warehouse.
-- Equality on warehouse_id, then the created_at range. The partial predicate
-- excludes restock rows the query never counts, and INCLUDE covers the
-- aggregate so only the index is read.
CREATE INDEX IF NOT EXISTS ix_stock_movement_sales
    ON stock_movement (warehouse_id, created_at) INCLUDE (variant_id, delta)
    WHERE reason = 'sale';

-- q06 - catalogue walk category -> products, the reverse of the
-- (product_id, category_id) primary key, which can only be used the other way.
CREATE INDEX IF NOT EXISTS ix_product_category_category
    ON product_category (category_id, product_id);

COMMIT;

-- New indexes make new access paths possible, so refresh the planner's
-- estimates before measuring.
ANALYZE customer_order;
ANALYZE payment;
ANALYZE order_line;
ANALYZE stock_movement;
ANALYZE product_category;
