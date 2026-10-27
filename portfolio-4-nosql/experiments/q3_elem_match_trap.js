// =============================================================================
//  Experiment - the array-condition trap that $elemMatch exists to close
//
//  Q3 asks for products with a Black 256GB variant. The obvious way to write
//  that is two dotted conditions on the same array field. It compiles, it uses
//  the index, and it is wrong: each condition is satisfied by *any* element,
//  so a product qualifies when one variant is Black and a different variant is
//  256GB.
//
//  This file runs both forms over the same documents and prints the gap. It is
//  kept out of queries/ because it is not a query anyone should run - it is the
//  reason q3_variant_filter.js wraps its conditions in $elemMatch.
// =============================================================================

load("queries/plan.js");

var wrong = {
    status: "active",
    "categories.slug": "electronics-phones",
    "variants.status": "active",
    "variants.attributes.colour": "Black",
    "variants.attributes.capacity": "256GB"
};

var right = {
    status: "active",
    "categories.slug": "electronics-phones",
    variants: {
        $elemMatch: {
            status: "active",
            "attributes.colour": "Black",
            "attributes.capacity": "256GB"
        }
    }
};

var wrongIds = db.catalogue.find(wrong, { _id: 1 }).toArray().map(function (d) { return d._id; });
var rightIds = db.catalogue.find(right, { _id: 1 }).toArray().map(function (d) { return d._id; });

print("two independent array conditions : " + wrongIds.length + " products");
print("one $elemMatch                   : " + rightIds.length + " products");

var falsePositives = wrongIds.filter(function (id) { return rightIds.indexOf(id) === -1; });
print("documents the wrong form includes anyway: " + falsePositives.length);

falsePositives.slice(0, 3).forEach(function (id) {
    var doc = db.catalogue.findOne({ _id: id }, { name: 1, variants: 1 });
    var colours = doc.variants.filter(function (v) { return v.attributes.colour === "Black"; })
                              .map(function (v) { return v.attributes.capacity; });
    var caps = doc.variants.filter(function (v) { return v.attributes.capacity === "256GB"; })
                           .map(function (v) { return v.attributes.colour; });
    print("  _id " + id + "  " + doc.name);
    print("      Black variants have capacity : " + colours.join(", "));
    print("      256GB variants have colour   : " + caps.join(", "));
});
