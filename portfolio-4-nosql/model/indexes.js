// =============================================================================
//  Portfolio 4 - secondary indexes for the catalogue collection
//
//  load_catalogue.py rebuilds the collection from scratch, so it ships with
//  only the default _id index and plans/before/ is a true unindexed baseline.
//  Every index below exists because one query in queries/ needs it; the
//  comment names that query. Nothing here is speculative.
//
//      mongosh "mongodb://127.0.0.1:27018/shopstack?directConnection=true" --file model/indexes.js
//      mongosh ... --file model/drop_indexes.js     // back to the baseline
//
//  MongoDB will not build a compound index over two *different* array fields -
//  the error is "cannot index parallel arrays" - but it will happily index two
//  fields of the *same* array, pairing them per array element. That single rule
//  decides most of this plan: a product has both categories[] and variants[], so
//  those two access paths can never share one index, while status and price,
//  both inside variants[], can.
// =============================================================================

var catalogue = db.getSiblingDB("shopstack").catalogue;

var planned = [
    {
        key: { "variants.sku": 1 },
        name: "uq_variants_sku",
        unique: true,
        why: [
            "q1 - product page by SKU. One index seek to one document.",
            "unique:true mirrors the relational uq_variant_sku constraint, with one",
            "difference worth knowing - a unique multikey index rejects a SKU shared by",
            "two products, but permits the same SKU twice inside one product's array."
        ]
    },
    {
        key: { "categories.slug": 1, status: 1 },
        name: "ix_categories_slug_status",
        why: [
            "q2 - category browse: equality on slug, then the status filter is answered",
            "from the index instead of the document.",
            "q3 - attribute filter: same two leading predicates.",
            "variants.price cannot join this index: both fields would be arrays."
        ]
    },
    {
        key: { "variants.status": 1, "variants.price": 1 },
        name: "ix_variants_status_price",
        why: [
            "q4 - clearance sweep: the only query without a category anchor, so it needs",
            "its own index. Both fields live in the same array, which is legal and makes",
            "the pair indexable per element - exactly the semantics $elemMatch asks for.",
            "Equality (status) first, then the range (price), as in the Portfolio 2 rule.",
            "Measured against a plain {variants.price:1}: 364 keys / 207 documents",
            "examined instead of 385 / 213."
        ]
    }
];

planned.forEach(function (spec) {
    var options = { name: spec.name };
    if (spec.unique) {
        options.unique = true;
    }
    print("creating " + spec.name + "  " + JSON.stringify(spec.key));
    spec.why.forEach(function (line) { print("    " + line); });
    printjson(catalogue.createIndex(spec.key, options));
});

print("");
print("q5 has no index on purpose: $group cannot use one (MongoDB has no loose");
print("index scan), so the brand league table is a collection scan either way.");
print("");

var stats = db.getSiblingDB("shopstack").runCommand({ collStats: "catalogue", scale: 1 });
print("index sizes (bytes):");
Object.keys(stats.indexSizes).sort().forEach(function (name) {
    print("    " + name.padEnd(28) + stats.indexSizes[name]);
});
print("total index size: " + stats.totalIndexSize + " bytes for " + stats.count + " documents");
print("");
print("current indexes:");
catalogue.getIndexes().forEach(function (ix) {
    print("    " + ix.name + "  " + JSON.stringify(ix.key) + (ix.unique ? "  unique" : ""));
});
