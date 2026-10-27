-- =============================================================================
--  Removes every index created by indexes.sql, returning the database to the
--  unindexed baseline that plans/before/ was captured against.
--
--      psql -d shopstack -f drop_indexes.sql
-- =============================================================================
BEGIN;

DROP INDEX IF EXISTS ix_order_date;
DROP INDEX IF EXISTS ix_payment_order_recent;
DROP INDEX IF EXISTS ix_order_customer;
DROP INDEX IF EXISTS ix_order_line_variant;
DROP INDEX IF EXISTS ix_stock_movement_sales;
DROP INDEX IF EXISTS ix_product_category_category;
DROP INDEX IF EXISTS ix_shipment_delivered;

COMMIT;
