-- =============================================================================
--  MIT 8103 Advanced Database Systems - Portfolio 1
--  Bulk loader for the ShopStack seed data.
--
--  Run from this directory (the \copy paths are relative to psql's working
--  directory):
--      cd portfolio-1-database-design
--      python seed.py
--      psql -d shopstack -f load.sql
--
--  Each \copy lists the columns explicitly, so CSV column order and PostgreSQL
--  column order are independent. An empty CSV field maps to NULL.
--  The whole load runs in one transaction: either every table loads or none does.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

TRUNCATE TABLE
    return_request, review, stock_movement, stock_level, shipment_line,
    shipment, payment, order_promotion, order_line, customer_order,
    promotion, cart_item, cart, customer_address, customer,
    product_supplier, supplier, warehouse, variant_attribute_value,
    product_variant, attribute_value, attribute, product_category,
    product, category, brand
RESTART IDENTITY CASCADE;

\copy brand                   (brand_id, name)                                                    FROM 'seed-data/brand.csv'                   WITH (FORMAT csv, HEADER true)
\copy category                (category_id, parent_category_id, name, slug)                       FROM 'seed-data/category.csv'                WITH (FORMAT csv, HEADER true)
\copy supplier                (supplier_id, name, country)                                        FROM 'seed-data/supplier.csv'                WITH (FORMAT csv, HEADER true)
\copy attribute               (attribute_id, name)                                                FROM 'seed-data/attribute.csv'               WITH (FORMAT csv, HEADER true)
\copy attribute_value         (value_id, attribute_id, value)                                     FROM 'seed-data/attribute_value.csv'         WITH (FORMAT csv, HEADER true)
\copy warehouse               (warehouse_id, name, city, country, region)                         FROM 'seed-data/warehouse.csv'               WITH (FORMAT csv, HEADER true)

\copy product                 (product_id, name, description, brand_id, status, created_at)       FROM 'seed-data/product.csv'                 WITH (FORMAT csv, HEADER true)
\copy product_category        (product_id, category_id)                                           FROM 'seed-data/product_category.csv'        WITH (FORMAT csv, HEADER true)
\copy product_supplier        (product_id, supplier_id, unit_cost, lead_time_days, is_primary)     FROM 'seed-data/product_supplier.csv'        WITH (FORMAT csv, HEADER true)
\copy product_variant         (variant_id, product_id, sku, price, weight_g, status)              FROM 'seed-data/product_variant.csv'         WITH (FORMAT csv, HEADER true)
\copy variant_attribute_value (variant_id, value_id)                                              FROM 'seed-data/variant_attribute_value.csv' WITH (FORMAT csv, HEADER true)

\copy customer                (customer_id, email, first_name, last_name, phone, status, created_at) FROM 'seed-data/customer.csv'              WITH (FORMAT csv, HEADER true)
\copy customer_address        (address_id, customer_id, line1, line2, city, region, postcode, country, is_default) FROM 'seed-data/customer_address.csv' WITH (FORMAT csv, HEADER true)

\copy cart                    (cart_id, customer_id, created_at, status)                          FROM 'seed-data/cart.csv'                    WITH (FORMAT csv, HEADER true)
\copy cart_item               (cart_id, variant_id, quantity)                                     FROM 'seed-data/cart_item.csv'               WITH (FORMAT csv, HEADER true)
\copy promotion               (promotion_id, code, description, discount_type, discount_value, min_spend, starts_at, ends_at) FROM 'seed-data/promotion.csv' WITH (FORMAT csv, HEADER true)

\copy customer_order          (order_id, customer_id, order_date, status, shipping_address_id, billing_address_id, currency, subtotal, discount_total, shipping_total, tax_total, grand_total) FROM 'seed-data/customer_order.csv' WITH (FORMAT csv, HEADER true)
\copy order_line              (order_id, variant_id, quantity, unit_price, line_total)             FROM 'seed-data/order_line.csv'              WITH (FORMAT csv, HEADER true)
\copy order_promotion         (order_id, promotion_id, discount_applied)                          FROM 'seed-data/order_promotion.csv'         WITH (FORMAT csv, HEADER true)
\copy payment                 (payment_id, order_id, provider, method, amount, status, provider_ref, created_at) FROM 'seed-data/payment.csv'  WITH (FORMAT csv, HEADER true)
\copy shipment                (shipment_id, order_id, carrier, tracking_number, status, dispatched_at, delivered_at) FROM 'seed-data/shipment.csv' WITH (FORMAT csv, HEADER true)
\copy shipment_line           (shipment_id, order_id, variant_id, quantity)                        FROM 'seed-data/shipment_line.csv'           WITH (FORMAT csv, HEADER true)

\copy stock_level             (variant_id, warehouse_id, quantity, reorder_point, updated_at)      FROM 'seed-data/stock_level.csv'             WITH (FORMAT csv, HEADER true)
\copy stock_movement          (movement_id, variant_id, warehouse_id, delta, reason, ref_order_id, created_at) FROM 'seed-data/stock_movement.csv' WITH (FORMAT csv, HEADER true)

\copy review                  (review_id, customer_id, product_id, rating, title, body, created_at) FROM 'seed-data/review.csv'                  WITH (FORMAT csv, HEADER true)
\copy return_request          (return_id, order_id, variant_id, quantity, reason, status, refund_amount, created_at) FROM 'seed-data/return_request.csv' WITH (FORMAT csv, HEADER true)

-- Explicit IDs were supplied above, so the identity sequences must be advanced
-- past the loaded maximum before any application-side INSERT can run.
SELECT setval(pg_get_serial_sequence('brand', 'brand_id'),           (SELECT COALESCE(MAX(brand_id), 1)           FROM brand));
SELECT setval(pg_get_serial_sequence('category', 'category_id'),     (SELECT COALESCE(MAX(category_id), 1)        FROM category));
SELECT setval(pg_get_serial_sequence('supplier', 'supplier_id'),     (SELECT COALESCE(MAX(supplier_id), 1)        FROM supplier));
SELECT setval(pg_get_serial_sequence('attribute', 'attribute_id'),   (SELECT COALESCE(MAX(attribute_id), 1)       FROM attribute));
SELECT setval(pg_get_serial_sequence('attribute_value', 'value_id'), (SELECT COALESCE(MAX(value_id), 1)           FROM attribute_value));
SELECT setval(pg_get_serial_sequence('warehouse', 'warehouse_id'),   (SELECT COALESCE(MAX(warehouse_id), 1)       FROM warehouse));
SELECT setval(pg_get_serial_sequence('product', 'product_id'),       (SELECT COALESCE(MAX(product_id), 1)         FROM product));
SELECT setval(pg_get_serial_sequence('product_variant', 'variant_id'), (SELECT COALESCE(MAX(variant_id), 1)       FROM product_variant));
SELECT setval(pg_get_serial_sequence('customer', 'customer_id'),     (SELECT COALESCE(MAX(customer_id), 1)        FROM customer));
SELECT setval(pg_get_serial_sequence('customer_address', 'address_id'), (SELECT COALESCE(MAX(address_id), 1)      FROM customer_address));
SELECT setval(pg_get_serial_sequence('cart', 'cart_id'),             (SELECT COALESCE(MAX(cart_id), 1)            FROM cart));
SELECT setval(pg_get_serial_sequence('promotion', 'promotion_id'),   (SELECT COALESCE(MAX(promotion_id), 1)       FROM promotion));
SELECT setval(pg_get_serial_sequence('customer_order', 'order_id'),  (SELECT COALESCE(MAX(order_id), 1)           FROM customer_order));
SELECT setval(pg_get_serial_sequence('payment', 'payment_id'),       (SELECT COALESCE(MAX(payment_id), 1)         FROM payment));
SELECT setval(pg_get_serial_sequence('shipment', 'shipment_id'),     (SELECT COALESCE(MAX(shipment_id), 1)        FROM shipment));
SELECT setval(pg_get_serial_sequence('stock_movement', 'movement_id'), (SELECT COALESCE(MAX(movement_id), 1)      FROM stock_movement));
SELECT setval(pg_get_serial_sequence('review', 'review_id'),         (SELECT COALESCE(MAX(review_id), 1)          FROM review));
SELECT setval(pg_get_serial_sequence('return_request', 'return_id'), (SELECT COALESCE(MAX(return_id), 1)          FROM return_request));

COMMIT;

-- Fresh statistics so that Portfolio 2 execution plans reflect the real data
-- distribution rather than an empty-table default.
ANALYZE;
