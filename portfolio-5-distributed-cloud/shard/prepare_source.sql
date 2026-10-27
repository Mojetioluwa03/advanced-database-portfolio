-- Build-time aid: decide which shard owns each customer and warehouse.
-- Lives in the single-node source database, not in any shard. Idempotent.
--
-- Customer home shard  = jurisdiction of the customer's default address.
-- Warehouse home shard = jurisdiction of the warehouse.
-- 'Test region' (the Portfolio 3 fixture) has country GB, so it follows the UK.

CREATE SCHEMA IF NOT EXISTS shardmap;

DROP TABLE IF EXISTS shardmap.customer_shard;
CREATE TABLE shardmap.customer_shard AS
SELECT c.customer_id,
       CASE WHEN a.region LIKE 'US-%' THEN 'us'
            WHEN a.region LIKE 'UK-%' THEN 'uk'
            WHEN a.region = 'EU'      THEN 'eu'
            ELSE 'uk' END AS shard
FROM customer c
JOIN customer_address a
  ON a.customer_id = c.customer_id AND a.is_default;
ALTER TABLE shardmap.customer_shard ADD PRIMARY KEY (customer_id);

DROP TABLE IF EXISTS shardmap.warehouse_shard;
CREATE TABLE shardmap.warehouse_shard AS
SELECT w.warehouse_id,
       CASE WHEN w.region LIKE 'US-%' THEN 'us'
            WHEN w.region LIKE 'UK-%' THEN 'uk'
            WHEN w.region = 'EU'      THEN 'eu'
            ELSE 'uk' END AS shard
FROM warehouse w;
ALTER TABLE shardmap.warehouse_shard ADD PRIMARY KEY (warehouse_id);

ANALYZE shardmap.customer_shard;
ANALYZE shardmap.warehouse_shard;
