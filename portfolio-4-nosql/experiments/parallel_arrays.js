// =============================================================================
//  Experiment - which compound indexes does MongoDB refuse to build?
//
//  Two claims in model/catalogue.md depend on this, so they are executed here
//  rather than quoted from the manual:
//
//    1. two fields from *different* arrays cannot share an index
//       ({categories.slug, variants.price}) - rejected;
//    2. two fields from the *same* array can
//       ({variants.status, variants.price}) - accepted, and that is the index
//       model/indexes.js builds for Q4.
//
//  Both attempts are cleaned up (a failed build leaves nothing behind).
// =============================================================================

function attempt(name, key) {
    try {
        db.catalogue.createIndex(key, { name: name });
        print("ACCEPTED  " + JSON.stringify(key));
        db.catalogue.dropIndex(name);
    } catch (e) {
        var reason = /cannot index parallel arrays.*/.exec(e.message);
        print("REJECTED  " + JSON.stringify(key));
        print("          " + (reason ? reason[0] : e.message));
    }
}

print("cross-array compound index (category + variant price):");
attempt("try_parallel", { "categories.slug": 1, "variants.price": 1 });

print("");
print("same-array compound index (variant weight + variant price):");
attempt("try_same_array", { "variants.weight_g": 1, "variants.price": 1 });
print("(ix_variants_status_price, built for Q4, is the same rule already in the");
print(" plan: both of its fields live inside variants[] too.)");

print("");
print("indexes remaining: " + db.catalogue.getIndexes().map(function (i) { return i.name; }).join(", "));
