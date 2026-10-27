# Portfolio 1 — Database Design and Modelling

**Marks:** 7 of 40
**Status:** design and implementation complete; ER diagram export pending
**Case study:** ShopStack (see the root README for the full case study statement)

---

## 1. What this activity delivers

| File | Purpose |
|---|---|
| `schema.sql` | 26 tables — keys, referential actions, check constraints, one partial unique index, one reconciliation view |
| `erd/` | Exported ER diagram (Chen notation for the conceptual model, crow's foot for the physical model) |
| `seed.py` | Deterministic data generator; same seed always produces the same dataset |
| `verify_seed.py` | Offline integrity checks against the generated CSVs (no database needed) |
| `load.sql` | Bulk `COPY` loader plus identity-sequence resynchronisation |
| `checks.sql` | Post-load verification queries, re-runnable at any time |
| `README.md` | This document: design rationale and normalisation argument |

The portfolio requires a case study description, an ER diagram, a relational schema,
keys, constraints and a normalisation explanation. The description is in the root
README; the remaining four are in this folder.

---

## 2. Conceptual model

The model is organised into six subject areas. Only the relationships that carry
meaning are shown; every foreign key in `schema.sql` is a real association.

```
Catalogue                     Supply and stock                Commerce
---------                     ----------------                --------
category ──parent──▶ category  supplier ◀─M:N─▶ product        customer ─1:N─▶ cart ─1:N─▶ cart_item
    ▲                              │                            customer ─1:N─▶ customer_order
    │ M:N                          │ product_supplier              │              ├─1:N─▶ order_line
product ──N:1──▶ brand             ▼                              │              ├─1:N─▶ payment
    │ 1:N                     product ◀── product_variant         │              ├─1:N─▶ shipment
    ▼                              │ 1:N                          │              └─M:N─▶ promotion
product_variant ──M:N──▶ attribute_value   ▼                      │                      (order_promotion)
    │                     attribute     stock_level ◀─N:1── warehouse
    │ 1:N                                   ▲
    └─────────▶ stock_movement ─────────────┘
                                          After-sales
                                          -----------
                          customer ──M:N──▶ product   (review)
                          return_request ──▶ order_line
```

Headline cardinalities:

| Relationship | Cardinality | Why it matters |
|---|---|---|
| product → product_variant | 1:N | Price and SKU live at variant level; the product is the marketing item |
| product ↔ category | M:N | A product appears in a leaf category and may be cross-listed |
| product_variant ↔ attribute_value | M:N | Attributes are data, not columns |
| product_variant ↔ warehouse | M:N via stock_level | Stock is per location, not global |
| customer_order → order_line | 1:N | Order line is the priced unit of purchase |
| customer_order → payment | 1:N | Retries, failures and instalments are all separate rows |
| customer_order → shipment | 1:N | Orders split across parcels |
| customer ↔ product | M:N via review | A customer reviews a product at most once |

---

## 3. Key design decisions

### 3.1 product vs product_variant

Splitting the marketing item from the sellable item is the decision that makes the
rest of the model work. A product has a name, description and brand; a variant has a
SKU, a price and a weight. Everything transactional — order lines, stock levels,
stock movements, cart items — references the variant, because that is what is actually
bought, counted and shipped. Products carry no price at all, which removes the classic
anomaly where a product-level price contradicts the prices actually charged.

### 3.2 Attributes as data, not columns

`attribute` → `attribute_value` → `variant_attribute_value` is a generalised model:
new attribute types (heel height, screen size, voltage) are inserted as rows, not as
schema migrations. The alternative — `colour`, `size`, `material` columns on
`product_variant` — breaks first normal form as soon as an item has two materials and
produces a sparse table full of NULLs.

### 3.3 Price on the order line is a snapshot, not a copy

`order_line.unit_price` duplicates `product_variant.price` **by design**. Variant
prices change over time; an invoice from March must still show March's price. If the
unit price were normalised away and joined at query time, historical invoices would
silently change whenever a product was repriced — a correctness bug, not a redundancy.

### 3.4 Stock as a ledger plus a snapshot

Two structures are kept deliberately:

- `stock_movement` is an append-only ledger. Every restock, sale, return, adjustment
  and damage is a row with a signed delta.
- `stock_level` is a materialised current balance per (variant, warehouse).

The ledger is the audit trail and the source of truth for *why* stock changed; the
snapshot is what the pick system reads on every request. `checks.sql` proves they
agree, and `verify_seed.py` proves the generated data satisfies the same invariant.

### 3.5 A composite foreign key that prevents a real error

`shipment_line` and `return_request` reference `order_line (order_id, variant_id)`
rather than each column separately:

```sql
FOREIGN KEY (order_id, variant_id) REFERENCES order_line (order_id, variant_id)
```

A single-column foreign key would happily allow a return against a variant that was
never on that order — a data error that is expensive to find later. The composite key
makes it structurally impossible.

### 3.6 Secondary indexes are intentionally absent

`schema.sql` defines only primary-key and uniqueness indexes. All performance indexes
are added in Portfolio 2 so that before/after execution plans can be measured honestly
against this baseline. Adding them now would remove the evidence P2 depends on.

---

## 4. Normalisation

### 4.1 First normal form — atomic values, no repeating groups

- No attribute is multi-valued: a variant's colour and size are rows in
  `variant_attribute_value`, not `colour1`/`colour2` columns.
- No repeating group: a customer's addresses are rows in `customer_address`, not
  `address1_line1`, `address2_line1`, … on `customer`.
- No comma-separated lists: a product's categories are rows in `product_category`.
- Each table has a declared primary key and every column holds a single scalar.

### 4.2 Second normal form — no partial dependencies

Every relation with a composite key was checked so that no non-key attribute depends
on only part of that key:

| Relation | Primary key | Argument |
|---|---|---|
| `stock_level` | (variant_id, warehouse_id) | Quantity is meaningless without both: 40 units in Manchester is not 40 units in Berlin |
| `order_line` | (order_id, variant_id) | Quantity and unit price belong to the pairing, not to the order or the variant alone |
| `product_category` | (product_id, category_id) | Pure association; no non-key attributes |
| `variant_attribute_value` | (variant_id, value_id) | Same |
| `cart_item`, `order_promotion`, `shipment_line` | composite | Same |

A deliberate contrast: a designer who put `warehouse.city` on `stock_level` would
create a partial dependency on `warehouse_id` alone — the classic 2NF violation
producing the same city string on hundreds of rows and an update anomaly when the
warehouse moves. `city` is therefore held once, in `warehouse`.

### 4.3 Third normal form — no transitive dependencies

- `brand.name` depends on `brand_id`, not on `product_id`; storing it on `product`
  would be transitive and would duplicate the brand string across every product.
- `supplier` details and `unit_cost` are on `product_supplier`, not on `product`.
  Cost is a property of the product–supplier pairing, not of the product.
- `category.name` and `category.slug` sit on `category`; a product references a
  category id only.
- `warehouse.region` and `country` are on `warehouse`, never on stock or movement rows.

### 4.4 Boyce–Codd normal form

All determinants in the schema are candidate keys. Two cases worth recording:

- `review` has `UNIQUE (customer_id, product_id)` alongside a surrogate primary key.
  `(customer_id, product_id)` is a candidate key, so the dependency
  `(customer_id, product_id) → rating, title, body` satisfies BCNF. The surrogate key
  exists only because foreign keys are simpler to write against a single column.
- `attribute_value` has `UNIQUE (attribute_id, value)` — the value string is unique
  *within* an attribute, not globally ("Black" as a colour and "Black" as a finish are
  different values). The determinant is a candidate key.

### 4.5 Deliberate denormalisation

Four stored values are derivable. Each is a considered trade-off, not an oversight:

| Stored value | Derivable from | Justification |
|---|---|---|
| `order_line.unit_price` | `product_variant.price` | Time-variant: the historical price is not the current price |
| `customer_order.subtotal`, `grand_total` | `order_line`, `payment` | Audit stability and read performance on an order-history screen; `v_order_reconciliation` proves they still agree with the lines |
| `stock_level.quantity` | `stock_movement.delta` | Materialised aggregate: the ledger is correct but too slow to sum on every pick |
| `payment.amount` | `customer_order.grand_total` | Payments can be partial, retried or refunded, so the amount is a property of the payment |

`v_order_reconciliation` exists specifically so that the second of these can be
audited: it returns stored totals next to values recomputed from `order_line`, and
`checks.sql` asserts the difference is zero.

---

## 5. Constraint inventory

Integrity is enforced in the database, not in application code.

| Mechanism | Examples |
|---|---|
| Primary keys | 20 surrogate keys plus 6 composite association keys |
| Unique constraints | `customer.email`, `product_variant.sku`, `promotion.code`, `brand.name`, `review (customer_id, product_id)` |
| Partial unique index | `ux_customer_default_address` — at most one default address per customer |
| Check constraints | `price > 0`, `quantity > 0`, `rating BETWEEN 1 AND 5`, `discount_total <= subtotal`, `line_total = quantity * unit_price`, status enumerations, `ends_at > starts_at` |
| Composite foreign keys | `shipment_line` and `return_request` → `order_line (order_id, variant_id)` |
| Referential actions | `CASCADE` on dependent rows (order lines, cart items, attribute values); `RESTRICT` on referenced master data (brand, warehouse, customer); `SET NULL` on `stock_movement.ref_order_id` so the ledger survives order deletion |
| Self-reference guard | `CHECK (parent_category_id <> category_id)` on `category` |

The `line_total = quantity * unit_price` check is worth noting: it makes the
arithmetic itself an enforced invariant, so a bad integration cannot write a line
whose total contradicts its own quantity and price.

---

## 6. How to run

```bash
# from this directory
python seed.py                 # writes seed-data/*.csv (scale: python seed.py 0.1)
python verify_seed.py          # offline checks, no database required

createdb  -h localhost -p 5432 -U postgres shopstack
psql -h localhost -p 5432 -U postgres -d shopstack -f schema.sql
psql -h localhost -p 5432 -U postgres -d shopstack -f load.sql
psql -h localhost -p 5432 -U postgres -d shopstack -f checks.sql
```

Substitute `-p 5433` throughout if you are using the portable cluster described in the
root README.

No local server? The root README's Route B builds a throwaway cluster from the
portable binaries — no installer, no admin rights, no Docker.

`load.sql` must run through `psql` (it uses `\copy`) and from this directory, because
the CSV paths are relative.

Measured here: schema builds in under a second, `load.sql` takes 3m44s for 1.35M rows
(dominated by foreign-key checks), `checks.sql` takes 1.9s.

---

## 7. Verification

### 7.1 Generated dataset

Full volume, seed `20261027`, generated in 33 seconds. Output is deterministic: the
same command reproduces these counts exactly.

| Table | Rows | Table | Rows |
|---|---:|---|---:|
| brand | 40 | customer_order | 200,000 |
| category | 40 | order_line | 440,127 |
| supplier | 60 | order_promotion | 35,142 |
| product | 10,000 | payment | 181,512 |
| product_category | 11,000 | shipment | 165,099 |
| product_variant | 21,560 | shipment_line | 343,312 |
| attribute | 3 | stock_level | 27,996 |
| attribute_value | 21 | stock_movement | 424,221 |
| variant_attribute_value | 43,120 | review | 67,669 |
| warehouse | 4 | return_request | 18,129 |
| customer | 50,000 | cart | 5,000 |
| customer_address | 65,090 | cart_item | 12,696 |
| product_supplier | 12,492 | promotion | 40 |

### 7.2 Integrity status

Both layers were executed on 2026-10-27 against PostgreSQL 16.15. `verify_seed.py`
checks the CSV output before loading; `checks.sql` checks the loaded database. The
full transcript of the second is committed at `verification/checks-output.txt`.

| Assertion | Offline (`verify_seed.py`) | In database (`checks.sql`) |
|---|---|---|
| `line_total = quantity * unit_price` | passed | §2 — 0 violations |
| Order subtotal equals its line sum | passed | §2 — 0 violations |
| `grand_total = subtotal − discount + shipping + tax` | passed | §2 — 0 violations |
| Settled orders have a payment equal to `grand_total` | passed | §3 — 0 violations |
| `stock_level` equals the movement ledger | passed | §4 — 0 violations |
| No negative stock | passed | §5 — 0 violations |
| One default address per customer | passed | §6 — 0 violations |
| No self-parenting categories | passed | §7 — 0 violations |
| `shipment_line` / `return_request` point at real order lines | passed | composite FK enforced |
| Reviews unique per customer and product | passed | FK + unique enforced |

Row counts returned by the database match the generated CSV exactly across all 26
tables (1,354,231 rows in total). Distributions are sane: 25 monthly buckets, six order
statuses, eight root categories each carrying 1,209–1,303 products.

### 7.3 A note on query form

The payment check originally used a per-order `LATERAL` subquery against `payment`. With
no index on `payment.order_id` that is 200,000 × 181,512 row visits; it did not finish
in five minutes and had to be cancelled. Rewritten as aggregate-then-join it returns the
same answer in under two seconds.

The result did not change — only the shape of the query did. That is Portfolio 2's
subject in miniature, and it is recorded here rather than quietly fixed, because the
unindexed baseline is the evidence P2 is measured against.

---

## 8. Limitations and what comes next

- Secondary indexes are deliberately omitted (see §3.6) — Portfolio 2 adds them and
  measures the effect on execution plans.
- The model stores one currency per order but no exchange-rate table; a production
  system would need historical FX rates to report across regions. Out of scope here,
  and noted rather than silently ignored.
- No slowly-changing-dimension treatment for product prices beyond the order-line
  snapshot; a full price-history table would be the next step.
- Portfolio 4 will re-model the catalogue, cart and movement log in NoSQL terms and
  must justify why each fits, using this relational model as the comparison point.
