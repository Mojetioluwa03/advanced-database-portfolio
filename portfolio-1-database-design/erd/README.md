# ER diagrams — ShopStack

Two diagrams of the same database, drawn in two notations for two audiences. They
are exported, not hand-drawn, so they cannot drift from the schema they describe.

| File | Notation | Built from | Shows |
|---|---|---|---|
| `conceptual_chen.svg` | Chen — rectangles, ellipses, diamonds | a declared conceptual spec in `generate_conceptual.py` | 15 entities, 16 relationships, cardinalities, key attributes |
| `physical_crowfoot.svg` | crow's foot — one box per table | live `pg_catalog` via `generate_erd.py` | all 26 tables, every column, PK/FK tags, all 33 foreign keys |
| `physical_crowfoot.mmd` | Mermaid `erDiagram` | the same `pg_catalog` read | the same physical model, in a form GitHub renders inline |
| `generate_conceptual.py` | — | — | regenerates the Chen diagram |
| `generate_erd.py` | — | — | regenerates both physical exports |

**Why two.** The conceptual model answers "what does the business talk about and how
do those things relate" — it has no table ids, no join tables, and no surrogate keys,
because none of those are business concepts. The physical model answers "what exactly
is in the database" and must match `schema.sql` row for row. Putting both in the
portfolio is the point of the exercise: the same fact (`a supplier supplies many
products, at a negotiated cost`) appears as one diamond in one diagram and as one
table (`product_supplier`) in the other.

## Regenerating

Both scripts need the schema loaded and a `psql` on the path (or `PSQL_BIN` set). The
physical export reads the portable cluster created for this portfolio on port 5433 by
default; override with `PGPORT`/`PGHOST`/`PGUSER`/`PGDATABASE`.

```bash
cd portfolio-1-database-design
psql -f schema.sql                 # if the database is empty
cd erd
python generate_erd.py             # 26 tables, 33 foreign keys
python generate_conceptual.py      # 15 entities, 16 relationships
```

`generate_erd.py` validates its own output with an XML parser before exiting and
prints the table/foreign-key counts; a malformed SVG or a missed constraint fails the
run rather than shipping a broken diagram.

## The conceptual model (Chen notation)

Rectangles are entities, ellipses are attributes (the underlined one is the key),
diamonds are relationships, and the number on each connector is that entity's
participation. Relationship attributes hang off the diamond.

| Relationship | Entities | Cardinality | Implemented as |
|---|---|---|---|
| makes | BRAND — PRODUCT | 1:N | `product.brand_id` |
| supplies | SUPPLIER — PRODUCT | M:N | `product_supplier`, carrying `unit_cost`, `lead_time_days`, `is_primary` |
| stocked at | WAREHOUSE — VARIANT | M:N | `stock_level`, carrying `quantity` and `reorder_point` |
| described by | ATTRIBUTE — VARIANT | M:N | `variant_attribute_value` → `attribute_value`, carrying `value` |
| has | PRODUCT — VARIANT | 1:N | `product_variant.product_id` |
| classified as | PRODUCT — CATEGORY | M:N | `product_category` |
| reviews | CUSTOMER — PRODUCT | M:N | `review`, carrying `rating`, `title`, `body` |
| holds | CART — VARIANT | M:N | `cart_item`, carrying `quantity` |
| owns | CUSTOMER — CART | 1:N | `cart.customer_id` |
| places | CUSTOMER — ORDER | 1:N | `customer_order.customer_id` |
| paid by | ORDER — PAYMENT | 1:N | `payment.order_id` |
| fulfilled by | ORDER — SHIPMENT | 1:N | `shipment.order_id` |
| contains | ORDER — ORDER_LINE | 1:N | `order_line.order_id` (part of its composite key) |
| applies | ORDER — PROMOTION | M:N | `order_promotion`, carrying `discount_applied` |
| refers to | ORDER_LINE — VARIANT | N:1 | `order_line.variant_id` |
| against | RETURN — ORDER_LINE | N:1 | composite FK `return_request (order_id, variant_id)` → `order_line` |
| parent of | CATEGORY — CATEGORY | 1:N | self-reference `category.parent_category_id` |

Three things this table makes visible:

- **Six diamonds are tables.** A many-to-many relationship with attributes cannot be
  stored in two foreign keys, so it becomes a table that carries the attributes. The
  conceptual diagram names the attributes; the physical diagram shows the table.
- **`contains` and `refers to` are one row type.** `order_line` is the child of both
  `customer_order` and `product_variant`; its primary key is the pair
  `(order_id, variant_id)`, which is what makes "return this line" expressible as a
  composite foreign key from `return_request`.
- **`against` is the reason that composite key exists.** A return names an order line,
  not just an order: the same variant can appear on several orders, and an order can
  contain several variants.

Deliberate omissions, to keep the diagram readable:

- **Non-key attributes are not drawn** except where they belong to a relationship.
  `schema.sql` is the authority for the full attribute list; drawing 150 ellipses
  would hide the relationships the diagram exists to show.
- **`customer_address` is not an entity here.** It is a 1:N detail of CUSTOMER with no
  relationship of its own, and the conceptual section of the activity README treats
  addresses as a customer attribute rather than a separate business object.
- **`shipment_line`, `stock_movement`, `attribute_value` and `order_promotion` do not
  appear as entities**, because each is either a relationship table or an attribute
  table in the conceptual model. They are all in the physical diagram.

## The physical model (crow's foot)

One box per table, in the order rows physically appear, with `PK` / `FK` / `PK·FK`
tags and the column type. Each foreign key is drawn as a line from the referencing
column's row to the referenced column's row, so the diagram encodes *which column*
points at *which key*, not merely "these tables are related".

- **Crow's foot at the child end** = zero or many; **tick at the parent end** = exactly
  one. Both come from `pg_constraint`; no cardinality is asserted that the schema does
  not enforce.
- **`PK·FK`** marks a column that is both part of the primary key and a foreign key —
  the join tables (`cart_item`, `stock_level`, `product_category`, `product_supplier`,
  `order_line`, `variant_attribute_value`, `order_promotion`, `return_request`,
  `shipment_line`) are built this way.
- **Layout** is layered by longest path to a root table, then ordered by one barycenter
  sweep. Connectors leave a table on its left edge, run vertically in the gap between
  columns, and enter the parent on its right edge. Where that route would still cut
  across a third table, the relationship is detoured below the diagram instead of
  being drawn through a box — those are the seven nested lines under the tables.
- **The colour bands are subject areas**, not schema ownership: catalogue, supply and
  stock, commerce, after-sales.

## Why the diagram is generated from `pg_catalog`

`schema.sql` and the live database are two artefacts, and it is possible for them to
disagree — a migration applied by hand, a constraint that failed, a table added during
an experiment. Reading `pg_constraint` proves the diagram matches what the database
actually enforces:

```sql
SELECT con.conname, ch.relname AS child, pa.relname AS parent,
       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
          FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS child_cols,
       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
          FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) AS parent_cols
FROM pg_constraint con
JOIN pg_class ch ON ch.oid = con.conrelid
JOIN pg_class pa ON pa.oid = con.confrelid
JOIN pg_namespace n ON n.oid = con.connamespace
WHERE con.contype = 'f' AND n.nspname = 'public';
```

The `unnest … WITH ORDINALITY` form matters. `information_schema.constraint_column_usage`
loses column order and cannot distinguish a composite key's parts: joining it the
obvious way produced four bogus column pairs for `return_request` and `shipment_line`,
which would have drawn both composite keys as nonsense. `pg_constraint.conkey` and
`confkey` keep the pairing integral.
