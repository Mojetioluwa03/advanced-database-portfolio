# Relational, document, and the other three families

The same ShopStack catalogue — 10,000 products, 21,560 variants, 43,120
attribute values, 40 brands, 40 categories — is modelled twice: as 26 normalised
relations in Portfolios 1–3, and as 10,000 documents here. The five query pairs
in `queries/` ask both models the same business questions and are measured the
same way (server-side execution time, three runs, median, warm cache).

## 1. The same five questions, asked of both models

| # | Query | Rows | PostgreSQL | Mongo, unindexed | Mongo, indexed | Documents examined |
|---|---|---|---|---|---|---|
| Q1 | Product page by SKU | 1 | 1.3 ms | 14 ms | < 1 ms | 1 |
| Q2 | Category browse, price band, page 1 | 20 | 4.6 ms | 16 ms | 4 ms | 344 |
| Q3 | Colour + capacity on the same variant | 11 | 14.3 ms | 15 ms | 3 ms | 337 |
| Q4 | Clearance sweep under GBP 20 | 199 | 5.1 ms | 29 ms | 4 ms | 207 |
| Q5 | Brand league table | 10 | 22.2 ms | 99 ms | 95 ms | 10,000 |

Method: server-side execution time, three runs after a discarded warm-up,
median, warm cache. SQL side from `plans/sql/` (`EXPLAIN (ANALYZE, BUFFERS)`,
parallel query and JIT off); Mongo side from `plans/{before,after}/`
(`explain("executionStats")`), with `results/mql_timings.csv` and
`results/sql_timings.csv` holding the raw numbers.

The row counts are the equivalence check. Every pair returns the same number of
documents — 1, 20, 11, 199, 10 — so the timings compare the same work, not two
different answers to the same question.

## 2. Where the document model wins

**Q1 — the product page.** The relational plan assembles the page from eight
relations and pivots 4 attribute rows back into a map; the Mongo plan is a
single index seek to a single document. The measured gap is 1.3 ms against
sub-millisecond, and the honest reading is not "16x faster": at 10,000 products
both are fast. What changes is the *shape* of the work — one seek instead of an
eight-relation assembly, at any catalogue size — and that shape is why the
aggregate exists.

**Q3 — attribute filters.** This is the largest honest gap: 14.3 ms in SQL
against 3 ms in Mongo, for the same 11 products. The relational query spends
4,005 shared buffers because each attribute predicate is a correlated `EXISTS`
through `variant_attribute_value` → `attribute_value` → `attribute`; two
predicates double it. The document compares two keys inside a variant. The
document model did not make filtering faster in general — it removed the EAV
join, which is the part of the relational design that existed to keep attributes
flexible.

**Q2 and Q4 are a wash**, and it is worth saying so: 4.6 ms against 4 ms, and
5.1 ms against 4 ms. A category browse and a price sweep are not deep joins,
PostgreSQL answers both from ordinary B-trees, and the document model's
advantage — no assembly — has nothing to remove. Anyone expecting an order of
magnitude here would be measuring folklore.

## 3. Where the relational model wins

The document model is better at the read the storefront performs most. It is
worse at the rest of this section, and each item is a direct consequence of the
decisions in `model/catalogue.md`.

**Q5 — the brand league table is 4x slower here.** 95 ms against 22 ms. The
report groups 21,560 unwound variants by brand and counts distinct products;
PostgreSQL hash-aggregates the same 21,560 rows in one pass and looks the brand
name up from a 40-row table. The document model has to `$unwind` every variant
array, and `$addToSet` of 9,501 product ids to count them. Embedding the brand
name saved a join that was cheaper than the work the aggregation now does.

**Point updates become document rewrites.** A price change in SQL is
`UPDATE product_variant SET price = ... WHERE variant_id = ...`: one row, in
place, plus one B-tree entry. Here the same change is a `$set` into an array
element, which rewrites the product document (~1 KB) and updates the affected
entries of the multikey price index. At this size that is one page write, not a
problem; at 1,000 variants per aggregate it would be.

**A rename fans out.** `brand` is 40 rows and is embedded in every product that
uses it, so renaming a brand is one row in SQL and ~250 documents here
(10,000 products over 40 brands). Renaming a leaf category is one row versus
every product listed in it, because the category's name and its breadcrumb
`path` are inside each document. These are rare events, which is why the
denormalisation is still worth it — but they are writes that SQL does not have
to think about, and this model does.

**Integrity is the application's job.** `product_category.category_id` is a
foreign key with `ON DELETE RESTRICT`; the database will refuse to delete a
category that products still reference. MongoDB has no foreign keys. Deleting a
category here leaves thousands of documents carrying a `slug` that resolves to
nothing, and nothing raises an error. The same applies to
`ck_variant_price CHECK (price > 0)`: the collection can be given a
`$jsonSchema` validator that rejects a non-positive price, but a validator is
opt-in at creation, is validated per document, and is not the same guarantee as
a constraint the planner can also use.

**Uniqueness is narrower.** `uq_variant_sku` guarantees no two variants share a
SKU. The unique multikey index `uq_variants_sku` guarantees no two *products*
share a SKU, but permits the same SKU to appear twice inside one product's
`variants` array. A violation that spans documents is caught; one inside a
document is not.

**Multi-document atomicity is possible but not free.** The checkout in
Portfolio 3 spans `customer_order`, `order_line`, `stock_level`,
`stock_movement` and `payment` in one transaction. MongoDB has multi-document
transactions, but they cost more than a single-document write and the stock
counter is exactly the hot row the aggregate was drawn to exclude. The ledger
stays relational in this portfolio.

## 4. Verdict for ShopStack

The two models are not competing for the same job.

- The **catalogue** is read as a page, in whole, far more often than it is
  written, and its writes are per-product. That is the access pattern an
  aggregate is for, and §2 shows the read collapsing from a nine-relation
  assembly to one seek.
- The **ledger** — orders, payments, stock movements — is written across
  entities by one business action and constrained across rows. That is the
  access pattern a relational engine is for, and Portfolio 3's transactions
  depend on it.

That split is the honest recommendation: a document store for the catalogue,
PostgreSQL for the ledger, with the product page joining them by one extra read
for stock.

The reversible alternative, if the aggregate boundary turns out to be wrong: keep
PostgreSQL as the system of record and *derive* the document store from it (a
materialised read model fed by triggers or CDC). Then the aggregate can be
reshaped or abandoned without migrating the source of truth, the consistency
story is one-directional, and the two models can be compared on identical data —
which is what this portfolio simulates by loading both from the same CSV.

## 5. The other three families on the same case study

The brief asks for a document/key-value/column/graph example. One is
implemented; the other three are treated here as analysis, because building
four stores for the same seven marks would be four times the setup and not four
times the insight.

### Key-value — the cart and the counters

`cart` and `cart_item` hold 5,000 carts and have no query beyond "fetch this
cart". A Redis hash per cart — `cart:{id}` → sku→quantity — is read and written
whole, expires automatically when abandoned (`EXPIRE`), and needs no schema.
Stock reservation is the other natural fit: `DECRBY stock:{sku} 1` is atomic,
and the Portfolio 3 guarded update becomes a single command.

What key-value cannot do is the catalogue. There are no secondary indexes: a
price band, a brand listing or a category browse would mean scanning every key.
Every access must already know the key, which is exactly what a storefront
search does not.

### Wide-column — order history and events

Partition by `customer_id`, cluster by `order_date DESC`, and "my orders" is one
partition read that scales with the number of orders the customer placed, not
with the 200,000 orders in the system. That is the query Portfolio 2 answers
with a join across four tables and a sort.

The catch is that the table is the query. Cassandra requires one table per
access pattern, no joins, and denormalisation by hand — the same copying as the
document model, but with the query fixed before the data is written. A
wide-column store would suit ShopStack's order history, price-change log and
clickstream; it would be a poor fit for a catalogue that product managers expect
to filter ad hoc.

### Graph — recommendations and the category tree

"Customers who bought this also bought" is a traversal:
product → order_line → order → order_line → product, restricted to the last
90 days. In SQL it is a self-join over 440,127 order lines plus a `GROUP BY`.
In a graph it is two hops from a node. The same engine handles n-level category
trees natively — Portfolio 2's `q06_category_tree_revenue.sql` needs a recursive
CTE for what is here a two-level tree — and fraud detection across shared
addresses, payment instruments and phone numbers.

None of that is the catalogue's job. Product CRUD is not graph-shaped: a product
has two or three relationships, and storing them as edges buys nothing that an
embedded array does not.

## 6. What I would not claim

- **These timings are not a benchmark.** 10,000 documents and 1.35M rows on a
  laptop, warm cache, no concurrency. They show the work each engine does for a
  given query, which is what the plans make visible; they do not predict
  throughput.
- **The document store has no concurrency evidence.** Portfolio 3 measured
  PostgreSQL under two sessions. Nothing here measures MongoDB under
  contention, so no claim is made about write scaling.
- **"NoSQL is faster" is not the conclusion.** Q1 is one seek against one
  seek-after-eight — both are milliseconds at this size. The difference is the
  amount of work, and it grows with the page's depth and the catalogue's
  normalisation, not with the clock speed.
