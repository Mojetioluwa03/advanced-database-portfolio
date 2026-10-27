# Portfolio 4 — NoSQL and Advanced Data Models

**Marks:** 7 of 40
**Status:** complete — document model loaded, five MQL queries executed against
both an unindexed and an indexed collection, four experiments, relational
equivalents measured
**Store:** MongoDB 9.0.4 (document)
**Interface:** MongoDB Query Language (MQL) — `find` and aggregation pipelines,
run through `mongosh` and the official driver

---

## 1. What this activity delivers

| Requirement | Demonstrated by | Evidence |
|---|---|---|
| A working document/key-value/column/graph example | A document model of the ShopStack catalogue — 10,000 product documents | `model/catalogue.md`, `results/load.txt` |
| The query language native to the family | MQL: `find`, `$match`/`$group`/`$unwind`/`$elemMatch` pipelines | `queries/q1…q5.js`, `plans/{before,after}/` |
| Justified model design | Aggregate boundary, embed-vs-reference per entity, attribute map vs EAV, index plan | `model/catalogue.md`, `model/indexes.js` |
| Query optimisation evidence | Five unindexed baseline plans and five indexed plans, one per query per phase | `results/mql_timings.csv`, `plans/` |
| Comparison with the relational model | Five MQL queries and five SQL queries returning the same rows | `comparison.md`, `queries/sql/`, `results/sql/` |
| The other three families | Key-value, wide-column and graph analysed for the same case study | `comparison.md` §5 |

The brief asks for "a document/key-value/column/graph example", singular. This
portfolio implements one model properly rather than four shallowly, and covers
the other three as analysis.

---

## 2. The model, in one paragraph

One document per product. The brand, the categories it is listed in (with a
pre-computed breadcrumb `path`), and every variant with its price and
attributes are inside the document, because the product page fetches them
together and a price change writes them together. Stock and reviews stay out:
stock changes on every sale in a different workflow, and reviews grow without
bound. The document measures 676 bytes on average; the whole collection is
6.5 MiB.

```json
{ "_id": 624, "name": "Verdant Coastal Earbuds", "brand": {"brand_id": 4, "name": "Verdant"},
  "categories": [{"category_id": 4, "name": "Audio", "slug": "electronics-audio",
                  "path": ["Electronics", "Audio"]}],
  "variants": [{"variant_id": 1314, "sku": "SKU-00624-1", "price": NumberDecimal("552.58"),
                "status": "active", "attributes": {"colour": "Green", "capacity": "1TB"}}] }
```

The full document is in `model/sample_document.json`; the reasoning behind every
field, and every field that is deliberately absent, is in `model/catalogue.md`.

Two consequences are worth stating up front because they shape the queries:

- **Price is per variant, inside an array.** A "cheapest price" or "under £20"
  filter has to reach into `variants`, and a filter on two attributes has to say
  that both apply to the *same* variant. `$elemMatch` is what says that.
- **`_id` is the natural key** (`product_id`), so the loader is idempotent and
  the same key joins the document to the relational schema.

---

## 3. Loading the same catalogue into both stores

`load_catalogue.py` reads the Portfolio 1 CSVs — the same files that seeded
PostgreSQL — so both stores hold the same 10,000 products. It assembles
variants, attribute maps, brand and category breadcrumb in memory, then drops
and rebuilds the collection.

Captured summary (`results/load.txt`):

```
documents        : 10,000
embedded variants: 21,560
avg document size: 676 bytes
collection size  : 6.5 MiB on disk (uncompressed)
indexes          : 1 (only _id at this point)
```

The loader leaves the collection **unindexed** on purpose: that is what makes
`plans/before/` a true baseline.

One data finding came out of building it. The seed CSVs write `created_at` as a
naive timestamp, and Portfolio 1 loaded it with the server's default zone
(`Africa/Lagos`, UTC+1), so the same product would have been an hour apart in
the two stores. The loader applies the same offset; the proper fix — emit an
offset from `seed.py` — is recorded in `model/catalogue.md` §7 rather than done,
because it would mean re-running the Portfolio 1 load.

---

## 4. The five queries

Each file is self-contained: it explains the business question and the access
path, runs the same pipeline through `explain("executionStats")` three times
after a discarded warm-up, then fetches the results.

| # | Query | MQL form | Relational form | Rows |
|---|---|---|---|---|
| Q1 | Product page by SKU | `find` on `variants.sku`, projection | 8 relations, two levels of `jsonb` aggregation, `LATERAL` pivot | 1 |
| Q2 | Category browse, £20–£200, page 1 | `$match` slug → `$set` min price over active variants → `$sort` → `$skip`/`$limit` | `GROUP BY … HAVING MIN(price)` | 20 |
| Q3 | Black **and** 256GB on the same variant | `$match` with `$elemMatch` → `$filter` projection | two correlated `EXISTS`, both keyed on `v.variant_id` | 11 |
| Q4 | Clearance sweep, any variant under £20 | `$elemMatch` range → `$filter` projection | join predicate on `product_variant` | 199 |
| Q5 | Brand league table, top 10 | `$unwind` → `$group` → `$addToSet` for distinct products | `GROUP BY brand` with `COUNT(DISTINCT)` | 10 |

All ten queries return the same row counts. That is the equivalence check: the
timings in §5 compare the same answers.

Q1's SQL equivalent is written to return the *same JSON document*, so the
comparison is not "a document versus eight rows" but one document assembled two
ways. `results/sql/q1_product_page.txt` shows the relational engine producing
the Mongo-shaped output.

---

## 5. Results: index plan, and the cost of each model

### 5.1 What the indexes do

`model/indexes.js` creates three, each earned by a query:

| Index | Serves | Keys examined | Documents examined | Median |
|---|---|---|---|---|
| `uq_variants_sku` (unique) | Q1 | 1 | 1 | < 1 ms |
| `ix_categories_slug_status` | Q2, Q3 | 344 / 337 | 344 / 337 | 4 ms / 3 ms |
| `ix_variants_status_price` | Q4 | 364 | 207 | 4 ms |

Against the unindexed baseline, every query except Q5 becomes an `IXSCAN`:

| Query | Before (COLLSCAN) | After (indexed) | Documents examined before → after |
|---|---|---|---|
| Q1 | 14 ms | < 1 ms | 10,000 → 1 |
| Q2 | 16 ms | 4 ms | 10,000 → 344 |
| Q3 | 15 ms | 3 ms | 10,000 → 337 |
| Q4 | 29 ms | 4 ms | 10,000 → 207 |
| Q5 | 99 ms | 95 ms | 10,000 → 10,000 |

Q5 gets no index because `$group` cannot use one — MongoDB has no loose index
scan — and the measurement confirms it: adding three indexes changed its
execution time by noise.

Q4 is the case where a multikey index shows its shape: 364 keys examined but
207 documents, because one document contributes one key per matching variant,
and eight products have two cheap variants.

### 5.2 Document store against relational

| Query | PostgreSQL | MongoDB (indexed) | Rows |
|---|---|---|---|
| Q1 product page | 1.3 ms | < 1 ms | 1 |
| Q2 category browse | 4.6 ms | 4 ms | 20 |
| Q3 attribute filter | 14.3 ms | 3 ms | 11 |
| Q4 clearance sweep | 5.1 ms | 4 ms | 199 |
| Q5 brand league table | 22.2 ms | 95 ms | 10 |

Read honestly, this says:

- **Q1 is a design win.** One seek instead of nine, at any catalogue size. At
  10,000 products both engines are fast, so the number is small; the shape is not.
- **Q3 is the biggest genuine gap** (4.7×). The relational side pays the EAV
  tax: two attribute predicates, each a correlated `EXISTS` through
  `variant_attribute_value` → `attribute_value` → `attribute`, 4,005 shared
  buffers. The document compares two keys in a sub-document.
- **Q2 and Q4 are a wash.** Neither query is a deep join, both engines use an
  index, and the document model has no assembly to remove.
- **Q5 loses, 4×.** The brand league table has to `$unwind` 21,560 variants and
  `$addToSet` 9,501 product ids to count distinct products; PostgreSQL
  hash-aggregates the same rows in one pass. Embedding the brand name saved a
  join that was cheaper than the aggregation it now requires.

`comparison.md` takes this further, including why the ledger — orders, payments,
stock — should stay relational, and what key-value, wide-column and graph stores
would each do for ShopStack.

---

## 6. Experiments

Three, all reproducible and all in `experiments/` with transcripts in
`results/experiment-*.txt`.

**`q3_elem_match_trap.js` — the array-condition trap.** Written as two dotted
paths, Q3's filter matches 23 products; with `$elemMatch` it matches 11. The 12
extras are products whose Black variant and 256GB variant are different
variants. The transcript prints three of them and shows the mismatch. This is
the single most important correctness difference between the two models: in SQL
the same-variant requirement is a property of the join, in Mongo it is a
property of how carefully the filter is written.

**`attribute_index.js` — a measured alternative, not adopted.** A compound index
on `variants.attributes.colour` + `variants.attributes.capacity` examines 56
documents for Q3 instead of 337, and the planner prefers it when it exists. It
is not in the plan because it serves exactly one filter shape; faceting needs an
index per facet or a search engine. If that filter became hot, it is a one-line
addition.

**`parallel_arrays.js` — the index rule, executed rather than quoted.**
`{categories.slug, variants.price}` is rejected with `cannot index parallel
arrays [variants] [categories]`; `{variants.weight_g, variants.price}` is
accepted, because both fields live in the same array. That rule is why Q2's
price band is a residual filter and why Q4's status could join its price index.

---

## 7. Limitations

- **No concurrency evidence.** Portfolio 3 measured PostgreSQL under two
  sessions. Nothing here measures MongoDB under contention, so no claim is made
  about write throughput or locking.
- **Not a benchmark.** 10,000 documents on a laptop with a warm cache. The
  numbers compare work done per query, not throughput at scale.
- **The attribute map is a convention, not a schema.** Every variant carries
  `colour` and one of `size`/`capacity`, but nothing enforces it: the load path
  guarantees it, MongoDB does not. A `$jsonSchema` validator could enforce the
  shape, and is not installed here.
- **Deep pagination is a `$skip`.** Q2 skips 0 rows; page 400 would walk 8,000
  index entries before returning anything. The usual fix is range pagination on
  `(from_price, _id)`, which the sort key already supports.
- **No consistency mechanism between the stores.** Both are loaded from the same
  CSV, which makes them comparable but not synchronised. A production system
  needs one to be derived from the other — see the reversible alternative in
  `comparison.md` §4.

---

## 8. Reproducing

Requires the portable MongoDB described in the root README (Route D), listening
on port 27018, and `pymongo` (pinned in `requirements.txt`):

```bash
pip install -r requirements.txt
cd portfolio-4-nosql
python load_catalogue.py          # 10,000 documents, no indexes
bash run_queries.sh               # baseline, indexes, indexed run, SQL side, experiments
```

`run_queries.sh` runs the whole sequence and rewrites `plans/` and `results/`.
The two halves can also be run separately:

```bash
bash capture_mql.sh before
mongosh "mongodb://127.0.0.1:27018/shopstack?directConnection=true" --file model/indexes.js
bash capture_mql.sh after
bash capture_sql.sh               # needs the PostgreSQL cluster from Portfolio 1
```

`MONGOSH_BIN`, `MONGO_URI`, `PSQL_BIN`, `PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`
and `PYTHON` override the defaults. The scripts look for `../../.mongo/bin` and
`../../.pg16/pgsql/bin` first, then fall back to `PATH`.

If `./run_queries.sh` gives "permission denied", the executable bit did not
survive the clone (`core.filemode=false` on this machine); run `bash run_queries.sh`.

---

## 9. Reflection

The result I did not expect was Q5. The catalogue was supposed to be the
document store's home ground, and the brand league table — a query with no
product anchor at all — turned out to be four times slower there, because the
aggregation has to unwind every array the reads never wanted unwound. The
aggregate is a good boundary for fetching a page and a bad one for counting
across all pages, and the same embedding that made Q1 cheap made Q5 expensive.

The second thing I did not expect was being wrong about the index rule. I had
written that two fields from one array could not share an index, and the server
rejected that claim as plainly as it rejected the index I thought was legal.
`experiments/parallel_arrays.js` exists because the correction is worth keeping
as evidence rather than quietly editing out.

The attribute experiment is the judgement call I am least certain of. An index
that examines 56 documents instead of 337 is a real improvement, and I rejected
it for a reason — one filter shape, and faceting needs a different tool — that
would be stronger if Q3 were not one of only five queries. If the brief had
asked for faceted search, the answer would flip.
