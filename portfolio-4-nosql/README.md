# Portfolio 4 — NoSQL and Advanced Data Models

**Marks:** 7 of 40
**Status:** not started
**Store:** MongoDB
**Interface:** MongoDB Query Language (MQL) via the official driver

## Scope

One NoSQL model, built properly, against the ShopStack catalogue.

The brief asks for "a document/key-value/column/graph example", so this portfolio
implements a single model rather than one of each. Breadth across the four families is
covered in `comparison.md` as analysis rather than as four separate deployments.

**Model: the product catalogue as a document store.**

A product document embeds its variants and their attributes:

```json
{
  "product_id": 1042,
  "name": "Northwind Premium Headphones",
  "brand": "Northwind",
  "categories": ["Electronics", "Electronics Audio"],
  "status": "active",
  "variants": [
    {"sku": "SKU-01042-1", "price": 89.99, "attributes": {"colour": "Black", "capacity": "256GB"}},
    {"sku": "SKU-01042-2", "price": 99.99, "attributes": {"colour": "White", "capacity": "256GB"}}
  ]
}
```

### Why this model, and the argument it has to make

In the relational schema, rendering one product page requires joining `product`,
`product_variant`, `variant_attribute_value`, `attribute_value` and `product_category`
— five tables to assemble one screen. In the document model it is one read of one
document, because variants and attributes are always fetched with their product and
never queried independently.

That is the aggregate boundary, and it is the whole argument. It also sets the limits,
which the write-up must state: a variant price change now rewrites the parent document,
and cross-product queries (all variants below £20, stock across products) are awkward
because the unit of atomicity is the whole product.

### Planned evidence

1. **Model definition** — collection design, embedding vs referencing decisions, index plan.
2. **Loader** — converts the Portfolio 1 `seed-data/product*.csv` output into documents,
   so both models describe the same 10,000 products.
3. **Queries** — product page assembly, category browse, attribute filter, price range,
   brand aggregation; each shown beside its SQL equivalent from Portfolio 1.
4. **Results and timings** — captured output, plus document size and index usage.
5. **Suitability discussion** — read/write patterns that favour the aggregate, and the
   ones that favour the relational model.

## Planned files

```
model/            collection design, sample documents, index definitions
load_catalogue.py imports Portfolio 1 CSV output into MongoDB
queries.mongodb   MQL queries with their expected output
queries.sql       the equivalent relational queries, for comparison
results/          captured output and timings
comparison.md     relational vs document, plus prose treatment of key-value,
                  wide-column and graph fits for the same case study
README.md         conclusions
```

## Optional extension

If time allows, the cart can be added as a key-value model (Redis) — short TTLs, one
read per request, no joins. This is explicitly a stretch and not required by the brief.
