-- Extract one jurisdiction's slice of ShopStack into CSVs.
--   psql -v outdir=C:/.../shards/eu/csv -c "SET shard.name='eu'" -f extract.sql
--
-- The shard filter is read from a session setting, not a psql variable: \copy
-- hands its query to the server verbatim, so :'shard' would arrive unexpanded.
--
-- Two domains are partitioned differently on purpose:
--   * order domain  (customer, address, cart, order, payment, shipment, review, return)
--     follows the customer's jurisdiction;
--   * stock domain  (stock_level, stock_movement) follows the warehouse's jurisdiction.
-- The catalogue tables are reference data and are copied whole to every shard.

\cd :outdir

\echo 'reference data (replicated to every shard)'
\copy (SELECT * FROM brand                  ORDER BY brand_id)          TO 'brand.csv' csv
\copy (SELECT * FROM category               ORDER BY category_id)       TO 'category.csv' csv
\copy (SELECT * FROM attribute              ORDER BY attribute_id)      TO 'attribute.csv' csv
\copy (SELECT * FROM attribute_value        ORDER BY value_id)          TO 'attribute_value.csv' csv
\copy (SELECT * FROM product                ORDER BY product_id)        TO 'product.csv' csv
\copy (SELECT * FROM product_category       ORDER BY product_id, category_id) TO 'product_category.csv' csv
\copy (SELECT * FROM product_variant        ORDER BY variant_id)        TO 'product_variant.csv' csv
\copy (SELECT * FROM variant_attribute_value ORDER BY variant_id, value_id) TO 'variant_attribute_value.csv' csv
\copy (SELECT * FROM supplier               ORDER BY supplier_id)       TO 'supplier.csv' csv
\copy (SELECT * FROM product_supplier       ORDER BY product_id, supplier_id) TO 'product_supplier.csv' csv
\copy (SELECT * FROM promotion              ORDER BY promotion_id)      TO 'promotion.csv' csv
\copy (SELECT * FROM warehouse              ORDER BY warehouse_id)      TO 'warehouse.csv' csv

\echo 'order domain (follows the customer)'
\copy (SELECT c.* FROM customer c JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY customer_id) TO 'customer.csv' csv
\copy (SELECT a.* FROM customer_address a JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY address_id) TO 'customer_address.csv' csv
\copy (SELECT x.* FROM cart x JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY cart_id) TO 'cart.csv' csv
\copy (SELECT ci.* FROM cart_item ci JOIN cart x USING (cart_id) JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY cart_id, variant_id) TO 'cart_item.csv' csv
\copy (SELECT o.* FROM customer_order o JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY order_id) TO 'customer_order.csv' csv
\copy (SELECT ol.* FROM order_line ol JOIN customer_order o USING (order_id) JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY order_id, variant_id) TO 'order_line.csv' csv
\copy (SELECT op.* FROM order_promotion op JOIN customer_order o USING (order_id) JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY order_id, promotion_id) TO 'order_promotion.csv' csv
\copy (SELECT p.* FROM payment p JOIN customer_order o USING (order_id) JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY payment_id) TO 'payment.csv' csv
\copy (SELECT s.* FROM shipment s JOIN customer_order o USING (order_id) JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY shipment_id) TO 'shipment.csv' csv
\copy (SELECT sl.* FROM shipment_line sl JOIN shipment s ON s.shipment_id = sl.shipment_id JOIN customer_order o ON o.order_id = sl.order_id JOIN shardmap.customer_shard m ON m.customer_id = o.customer_id WHERE m.shard = current_setting('shard.name') ORDER BY sl.shipment_id, sl.variant_id) TO 'shipment_line.csv' csv
\copy (SELECT rr.* FROM return_request rr JOIN customer_order o USING (order_id) JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY return_id) TO 'return_request.csv' csv
\copy (SELECT r.* FROM review r JOIN shardmap.customer_shard m USING (customer_id) WHERE m.shard = current_setting('shard.name') ORDER BY review_id) TO 'review.csv' csv

\echo 'stock domain (follows the warehouse)'
\copy (SELECT s.* FROM stock_level s JOIN shardmap.warehouse_shard w USING (warehouse_id) WHERE w.shard = current_setting('shard.name') ORDER BY warehouse_id, variant_id) TO 'stock_level.csv' csv
\copy (SELECT s.* FROM stock_movement s JOIN shardmap.warehouse_shard w USING (warehouse_id) WHERE w.shard = current_setting('shard.name') ORDER BY movement_id) TO 'stock_movement.csv' csv
