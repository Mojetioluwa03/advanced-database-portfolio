-- Load one shard from the CSVs produced by extract.sql.
--   psql -d shopstack_eu -v indir=C:/.../shards/eu/csv -f load.sql
--
-- Order matters: the catalogue first, then the order domain, then the stock
-- domain. stock_movement is loaded after dropping its reference to
-- customer_order, because the warehouse that moved the stock and the customer
-- who ordered it are not necessarily in the same jurisdiction.

\cd :indir

\echo 'reference data'
\copy warehouse                 FROM 'warehouse.csv' csv
\copy supplier                  FROM 'supplier.csv' csv
\copy brand                     FROM 'brand.csv' csv
\copy category                  FROM 'category.csv' csv
\copy attribute                 FROM 'attribute.csv' csv
\copy attribute_value           FROM 'attribute_value.csv' csv
\copy product                   FROM 'product.csv' csv
\copy product_category          FROM 'product_category.csv' csv
\copy product_variant           FROM 'product_variant.csv' csv
\copy variant_attribute_value   FROM 'variant_attribute_value.csv' csv
\copy promotion                 FROM 'promotion.csv' csv
\copy product_supplier          FROM 'product_supplier.csv' csv

\echo 'order domain'
\copy customer                  FROM 'customer.csv' csv
\copy customer_address          FROM 'customer_address.csv' csv
\copy cart                      FROM 'cart.csv' csv
\copy cart_item                 FROM 'cart_item.csv' csv
\copy customer_order            FROM 'customer_order.csv' csv
\copy order_line                FROM 'order_line.csv' csv
\copy order_promotion           FROM 'order_promotion.csv' csv
\copy payment                   FROM 'payment.csv' csv
\copy shipment                  FROM 'shipment.csv' csv
\copy shipment_line             FROM 'shipment_line.csv' csv
\copy return_request            FROM 'return_request.csv' csv
\copy review                    FROM 'review.csv' csv

-- Cross-shard edge: a stock movement records work done at a warehouse, and the
-- order it refers to may belong to a customer in another jurisdiction. The
-- referential integrity is enforced by the router's reconciliation query
-- instead; see experiments/e6_cross_shard_reference.sh.
ALTER TABLE stock_movement DROP CONSTRAINT IF EXISTS stock_movement_ref_order_id_fkey;

\echo 'stock domain'
\copy stock_level               FROM 'stock_level.csv' csv
\copy stock_movement            FROM 'stock_movement.csv' csv

\echo 'sequences'
SELECT setval(pg_get_serial_sequence('brand', 'brand_id'),             (SELECT COALESCE(MAX(brand_id), 1) FROM brand));
SELECT setval(pg_get_serial_sequence('category', 'category_id'),       (SELECT COALESCE(MAX(category_id), 1) FROM category));
SELECT setval(pg_get_serial_sequence('supplier', 'supplier_id'),       (SELECT COALESCE(MAX(supplier_id), 1) FROM supplier));
SELECT setval(pg_get_serial_sequence('attribute', 'attribute_id'),     (SELECT COALESCE(MAX(attribute_id), 1) FROM attribute));
SELECT setval(pg_get_serial_sequence('attribute_value', 'value_id'),   (SELECT COALESCE(MAX(value_id), 1) FROM attribute_value));
SELECT setval(pg_get_serial_sequence('warehouse', 'warehouse_id'),     (SELECT COALESCE(MAX(warehouse_id), 1) FROM warehouse));
SELECT setval(pg_get_serial_sequence('product', 'product_id'),         (SELECT COALESCE(MAX(product_id), 1) FROM product));
SELECT setval(pg_get_serial_sequence('product_variant', 'variant_id'), (SELECT COALESCE(MAX(variant_id), 1) FROM product_variant));
SELECT setval(pg_get_serial_sequence('customer', 'customer_id'),       (SELECT COALESCE(MAX(customer_id), 1) FROM customer));
SELECT setval(pg_get_serial_sequence('customer_address', 'address_id'), (SELECT COALESCE(MAX(address_id), 1) FROM customer_address));
SELECT setval(pg_get_serial_sequence('cart', 'cart_id'),               (SELECT COALESCE(MAX(cart_id), 1) FROM cart));
SELECT setval(pg_get_serial_sequence('promotion', 'promotion_id'),     (SELECT COALESCE(MAX(promotion_id), 1) FROM promotion));
SELECT setval(pg_get_serial_sequence('customer_order', 'order_id'),    (SELECT COALESCE(MAX(order_id), 1) FROM customer_order));
SELECT setval(pg_get_serial_sequence('payment', 'payment_id'),         (SELECT COALESCE(MAX(payment_id), 1) FROM payment));
SELECT setval(pg_get_serial_sequence('shipment', 'shipment_id'),       (SELECT COALESCE(MAX(shipment_id), 1) FROM shipment));
SELECT setval(pg_get_serial_sequence('stock_movement', 'movement_id'), (SELECT COALESCE(MAX(movement_id), 1) FROM stock_movement));
SELECT setval(pg_get_serial_sequence('review', 'review_id'),           (SELECT COALESCE(MAX(review_id), 1) FROM review));
SELECT setval(pg_get_serial_sequence('return_request', 'return_id'),   (SELECT COALESCE(MAX(return_id), 1) FROM return_request));

ANALYZE;
