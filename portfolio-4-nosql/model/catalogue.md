# The ShopStack catalogue as documents

Design notes for `db.catalogue` — the collection `load_catalogue.py` builds and
the five queries in `queries/` run against.

## 1. What the aggregate is

One document per **product**. Inside it: the marketing record, the brand, the
categories it is listed in (with their breadcrumb), and every variant with its
price and attributes.

The boundary was drawn by asking which data is fetched together *and* written
together by one business action:

- A product page needs the product, its brand, its categories and all of its
  variants. Nothing on that page is worth fetching alone, so nothing on it is
  stored alone.
- A price change is a variant edit. It is also, unavoidably, a write to one
  product's document — that is the cost of this boundary and it is accepted.
- Stock is not on the page's critical path in the same way: it changes on every
  sale, in a different workflow, at a different rate. It stays outside the
  aggregate (§4).
- Reviews are unbounded in principle. They stay outside too (§4).

The average document is small — 10,000 products, 21,560 variants, at most four
variants per product and two attribute values per variant, so a document holds
at most four variant sub-documents and eight attribute pairs.

## 2. The document

```json
{
  "_id": 624,
  "name": "Verdant Coastal Earbuds",
  "description": "Coastal earbuds from Verdant. Electronics range.",
  "status": "active",
  "created_at": ISODate("2023-05-03T14:59:52Z"),
  "brand": { "brand_id": 4, "name": "Verdant" },
  "categories": [
    {
      "category_id": 4,
      "name": "Audio",
      "slug": "electronics-audio",
      "path": ["Electronics", "Audio"]
    }
  ],
  "variants": [
    {
      "variant_id": 1314,
      "sku": "SKU-00624-1",
      "price": NumberDecimal("552.58"),
      "weight_g": 2828,
      "status": "active",
      "attributes": { "colour": "Green", "capacity": "1TB" }
    }
  ]
}
```

Every field is there because a query or the product page reads it. There is no
`variant_count`, no `min_price`, no `category_id` duplicated at the top level:
derived values would have to be maintained on every write and would drift.

## 3. What is embedded, and what that costs

| Embedded | Why | Cost |
|---|---|---|
| `brand` (id + name) | The page shows the brand name; the brand table has 40 rows and is joined to every product | Renaming a brand updates every product document that carries it |
| `categories` with `path` | The page renders a breadcrumb and the browse query filters by slug. `path` removes the self-join PostgreSQL needs to find the parent category | A product re-categorised twice exists in two places until both are updated |
| `variants[]` | Variants are only ever read with their product, and 4 is the documented maximum | A price change rewrites the parent document (see §6) |
| `attributes` as a name→value map | Attribute values are read only to render or filter a variant, and the relational EAV needs two joins to reach a value | Field names are data, so the set of queryable attribute keys is a convention, not a schema (§5) |

Three of these four are "the page needs it, the row is small, and it changes
rarely". The fourth — the attributes — is a modelling decision about the EAV
that is worth spelling out, because it is where the two models differ most.

## 4. What is deliberately not embedded

**Stock (`stock_level`, 27,998 rows for 21,560 variants).** Quantity changes on
every sale and is written by the checkout path in Portfolio 3. Embedding it
would make every sale rewrite a product document, turn the product into the
unit of contention for stock, and copy the quantity into a second place that
the ledger in `stock_movement` does not control. The product page therefore
costs one document read plus one stock read — that second read is the price of
keeping the aggregate writable.

**Reviews (67,669 rows; at most 26 per product, 6.8 on average, growing).** At
today's size an array of reviews would fit in 16 MB. The argument against
embedding is not size today, it is that nothing bounds tomorrow's: a popular
product's review array grows forever, and every one of those inserts rewrites
the whole document. A review is also written by a different workflow (a shopper
submitting a form) from the one that writes the catalogue.

If the page needed an average rating, the right shape would be a *summary*
embedded in the product (`rating_avg`, `rating_count`) incremented atomically
by the review writer, with the individual reviews referenced. That is a second,
smaller denormalisation, and it is not implemented here because no graded query
needs it.

## 5. Attributes: map vs EAV

In PostgreSQL the attributes are three tables — `attribute`, `attribute_value`,
`variant_attribute_value` — and a filter on two of them is two correlated
`EXISTS` subqueries, each a two-hop join (`queries/sql/q3_variant_filter.sql`).
In the document they are one key in a sub-document.

The map is not free. Three things it changes:

1. **The key set is data but the query shape is not.** Every variant carries
   `colour`, and exactly one of `size` or `capacity` — Electronics leaves use
   `capacity`, the other 28 leaves use `size`. A query for `capacity` returns
   nothing for Fashion, silently, where the relational `attribute` table would
   at least have a row saying the attribute exists.
2. **A field name containing `.` or `$` cannot be stored**, so the loader
   rejects such names. The relational model has no equivalent restriction.
3. **Two conditions on the same array element need `$elemMatch`.** Written as
   two dotted paths, `colour` and `capacity` may be satisfied by different
   variants of the same product. `experiments/q3_elem_match_trap.js` measures
   the gap: 23 products pass the wrong form, 11 pass the correct one.

Point 3 is the sharpest difference between the models. In SQL the conditions
are correlated on `v.variant_id` and the same-variant requirement is a property
of the join, not of the author's care.

## 6. What embedding costs, concretely

The unit of atomicity is the product. That gives a checkout one clean read, and
it gives these write patterns:

- **Variant price change**: one `$set` on `variants.$.price` (positional
  operator) — cheap, and atomic for that product.
- **Adding a variant**: `$push` — grows the document.
- **Brand rename**: update every product carrying that brand. 40 brands over
  10,000 products means ~250 documents per rename; done as one
  `updateMany` it is a single command but not a transaction with anything else.
- **Category rename**: the same, plus the `path` array of every child product.

None of these are hidden; they are the invoice for the read path.

## 7. Money and time

`price` is stored as `Decimal128`, the BSON type that corresponds to
`NUMERIC(12,2)`, because binary floating point cannot represent 0.1 exactly and
price comparisons would drift. The loader converts the CSV string straight to
`Decimal`, never through `float`.

The reversible alternative, if exactness and arithmetic both matter more than
readability, is integer minor units (`price_cents: 55258`). It avoids decimal
entirely, aggregates trivially, and makes rounding rules explicit in the
application. It is not used here because it departs from how the relational
side models the same column, which would make the two query sets harder to
compare.

`created_at` is a BSON `Date` — always UTC, matching `TIMESTAMPTZ`. One
wrinkle: the seed CSV writes the timestamp with no zone
(`2023-05-03 15:59:52`), and Portfolio 1 loaded it with the server's default
zone, `Africa/Lagos` (UTC+1, no DST). `load_catalogue.py` applies the same
offset, so the document holds the same instant as the `TIMESTAMPTZ` rather
than one an hour later. The proper fix is for `seed.py` to emit an offset;
that would mean re-running the Portfolio 1 load, so it is recorded here rather
than done.

## 8. Index plan

Three indexes, each earned by a query, in `indexes.js`:

| Index | Serves | Why this shape |
|---|---|---|
| `uq_variants_sku` (unique) | Q1 | One seek to one document |
| `ix_categories_slug_status` | Q2, Q3 | Equality on both fields; the category bounds the scan before the price or attribute filter runs |
| `ix_variants_status_price` | Q4 | Equality first, then the range; both fields are inside the same array, so they pair per element |

Q5 gets no index: `$group` cannot use one, so the brand league table is a
collection scan in either engine.

The rule that shapes this plan is about **parallel arrays**. MongoDB refuses a
compound index that spans two different array fields, because the key would have
to pair elements of one array with elements of the other, and it will happily
index two fields of the *same* array, pairing them per element. A product has
`categories[]` and `variants[]`, so:

- `{categories.slug, variants.price}` is rejected — `cannot index parallel
  arrays [variants] [categories]`, reproduced in
  `experiments/parallel_arrays.js`. The price band in Q2 therefore cannot ride
  in the category index and is applied as a residual filter over the 344
  documents the category selects.
- `{variants.status, variants.price}` is accepted, because both fields are
  inside `variants[]`. That is Q4's index, and it examines 364 keys and 207
  documents against 385 and 213 for a plain `{variants.price: 1}`.
- An attribute index is **not** added, although it was measured: a compound
  `{variants.attributes.colour, variants.attributes.capacity}` examines 56
  documents for Q3 instead of 337. It is rejected because it serves exactly one
  filter shape — colour then capacity, in that order — while faceting needs an
  index per facet or a search engine, which is outside this portfolio. The
  transcript is `results/experiment-attribute_index.txt`; adopting it later is a
  one-line change to `indexes.js` if that filter becomes hot.

A PostgreSQL B-tree has no such restriction: it indexes one column per index and
the planner combines them, so no access path is lost to the shape of another.

## 9. Measured footprint

From `results/load.txt` and `results/index_build.txt`:

- 10,000 documents holding 21,560 variants, 43,120 attribute values and 11,000
  category links.
- Average document 676 bytes; collection 6.5 MiB uncompressed.
- Indexes: 792 KB total — `uq_variants_sku` 300 KB, `ix_variants_status_price`
  412 KB, `ix_categories_slug_status` 76 KB, `_id_` 4 KB.

For comparison, the same catalogue in PostgreSQL occupies 26 tables; the five P4
query plans read 216 to 4,005 shared buffers each, which is 1.7 MB to 32 MB of
8 KB pages touched per query.
