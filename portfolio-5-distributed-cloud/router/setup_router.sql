-- Router database: one logical ShopStack, three physical shards.
--
--   createdb -h 127.0.0.1 -p 5433 -U postgres shopstack_router
--   psql -d shopstack_router -f .../portfolio-1-database-design/schema.sql
--   psql -d shopstack_router -f router/setup_router.sql
--
-- The canonical (empty) tables come from the Portfolio 1 schema so the foreign
-- tables have something to copy their column definitions from. Nothing is stored
-- in them; every row lives on a shard.

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

DROP SCHEMA IF EXISTS shard CASCADE;
CREATE SCHEMA shard;

DROP SERVER IF EXISTS shard_eu CASCADE;
DROP SERVER IF EXISTS shard_uk CASCADE;
DROP SERVER IF EXISTS shard_us CASCADE;

CREATE SERVER shard_eu FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '127.0.0.1', port '5441', dbname 'shopstack_eu', keep_connections 'on');
CREATE SERVER shard_uk FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '127.0.0.1', port '5442', dbname 'shopstack_uk', keep_connections 'on');
CREATE SERVER shard_us FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '127.0.0.1', port '5443', dbname 'shopstack_us', keep_connections 'on');

DO $$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['shard_eu','shard_uk','shard_us'] LOOP
    EXECUTE format('CREATE USER MAPPING FOR postgres SERVER %I OPTIONS (user ''postgres'')', s);
  END LOOP;
END $$;

-- Foreign tables: the sharded tables, once per shard. PostgreSQL rejects
-- CREATE FOREIGN TABLE ... (LIKE ...), so the column list is generated from the
-- catalogue — which also keeps the router honest if the Portfolio 1 schema moves.
DO $$
DECLARE
  t   record;
  s   record;
  cols text;
BEGIN
  FOR t IN SELECT * FROM (VALUES
             ('customer',       'customer'),
             ('customer_order', 'order'),
             ('order_line',     'order_line'),
             ('stock_level',    'stock'),
             ('stock_movement', 'movement'),
             ('product_variant','variant')
           ) AS v(tbl, alias) LOOP
    FOR s IN SELECT * FROM (VALUES
               ('eu', 'shard_eu'),
               ('uk', 'shard_uk'),
               ('us', 'shard_us')
             ) AS v(sfx, srv) LOOP
      SELECT string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum)
        INTO cols
      FROM pg_attribute a
      WHERE a.attrelid = format('public.%I', t.tbl)::regclass
        AND a.attnum > 0
        AND NOT a.attisdropped;
      EXECUTE format(
        'CREATE FOREIGN TABLE shard.%I (%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
        t.alias || '_' || s.sfx, cols, s.srv, 'public', t.tbl);
    END LOOP;
  END LOOP;
END $$;

-- Fan-out views: every query through these touches all three shards.
CREATE VIEW order_all AS
  SELECT 'eu'::text AS shard, o.* FROM shard.order_eu o
  UNION ALL SELECT 'uk', o.* FROM shard.order_uk o
  UNION ALL SELECT 'us', o.* FROM shard.order_us o;

CREATE VIEW customer_all AS
  SELECT 'eu'::text AS shard, c.* FROM shard.customer_eu c
  UNION ALL SELECT 'uk', c.* FROM shard.customer_uk c
  UNION ALL SELECT 'us', c.* FROM shard.customer_us c;

CREATE VIEW stock_all AS
  SELECT 'eu'::text AS shard, s.* FROM shard.stock_eu s
  UNION ALL SELECT 'uk', s.* FROM shard.stock_uk s
  UNION ALL SELECT 'us', s.* FROM shard.stock_us s;

CREATE VIEW movement_all AS
  SELECT 'eu'::text AS shard, m.* FROM shard.movement_eu m
  UNION ALL SELECT 'uk', m.* FROM shard.movement_uk m
  UNION ALL SELECT 'us', m.* FROM shard.movement_us m;

-- The routing key in one place. A request that carries a jurisdiction can be
-- answered from a single shard; one that does not must fan out.
CREATE OR REPLACE FUNCTION jurisdiction_shard(region text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN region LIKE 'US-%' THEN 'us'
              WHEN region LIKE 'UK-%' THEN 'uk'
              WHEN region = 'EU'      THEN 'eu'
              ELSE 'uk' END;
$$;

-- Key-based router: exactly one shard is contacted.
CREATE OR REPLACE FUNCTION route_orders(p_jurisdiction text)RETURNS TABLE (shard text, order_id integer, customer_id integer,
               order_date timestamptz, status varchar, grand_total numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_jurisdiction = 'eu' THEN
    RETURN QUERY SELECT 'eu', o.order_id, o.customer_id, o.order_date, o.status, o.grand_total FROM shard.order_eu o;
  ELSIF p_jurisdiction = 'uk' THEN
    RETURN QUERY SELECT 'uk', o.order_id, o.customer_id, o.order_date, o.status, o.grand_total FROM shard.order_uk o;
  ELSIF p_jurisdiction = 'us' THEN
    RETURN QUERY SELECT 'us', o.order_id, o.customer_id, o.order_date, o.status, o.grand_total FROM shard.order_us o;
  ELSE
    RAISE EXCEPTION 'unknown jurisdiction %', p_jurisdiction;
  END IF;
END $$;

-- Correct distributed aggregation. A UNION ALL view cannot push an aggregate
-- down (the planner sees an Append and aggregates after transferring one row
-- per shard row), so the partial aggregates are requested per shard and only
-- their results cross the network.
CREATE OR REPLACE FUNCTION total_orders() RETURNS bigint
LANGUAGE sql STABLE AS $$
  SELECT (SELECT count(*) FROM shard.order_eu)
       + (SELECT count(*) FROM shard.order_uk)
       + (SELECT count(*) FROM shard.order_us);
$$;

CREATE OR REPLACE FUNCTION status_counts()
RETURNS TABLE (status varchar, orders bigint)
LANGUAGE sql STABLE AS $$
  SELECT s.status, sum(s.n)::bigint
  FROM (
        SELECT status, count(*) AS n FROM shard.order_eu GROUP BY status
  UNION ALL SELECT status, count(*)     FROM shard.order_uk GROUP BY status
  UNION ALL SELECT status, count(*)     FROM shard.order_us GROUP BY status
       ) s
  GROUP BY s.status
  ORDER BY s.status;
$$;
