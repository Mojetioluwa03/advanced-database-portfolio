// =============================================================================
//  Q1 - Product page by SKU
//
//  Business question : a shopper opens /p/SKU-00624-1. Render everything the
//                     page shows: name, description, brand, breadcrumb
//                     categories, and every variant with its attributes.
//  Access path      : one equality lookup on variants.sku, then the document is
//                     already the answer - variants and attributes are inside it.
//  Expected output  : 1 document, ~1 KB.
//
//  The relational equivalent (queries/sql/q1_product_page.sql) returns the same
//  JSON shape, but has to assemble it from nine tables and pivot the
//  attribute/value rows back into a map.
// =============================================================================

load("queries/plan.js");

var filter = { "variants.sku": "SKU-00624-1" };
var projection = {
    name: 1,
    description: 1,
    status: 1,
    brand: 1,
    categories: 1,
    "variants.variant_id": 1,
    "variants.sku": 1,
    "variants.price": 1,
    "variants.weight_g": 1,
    "variants.status": 1,
    "variants.attributes": 1
};

reportPlan("Q1  product page by SKU", function () {
    return db.catalogue.find(filter, projection).explain("executionStats");
});
showResults(db.catalogue.find(filter, projection).toArray(), 1);
