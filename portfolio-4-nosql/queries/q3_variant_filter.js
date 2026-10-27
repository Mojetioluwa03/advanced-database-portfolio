// =============================================================================
//  Q3 - Variant attribute filter: Black AND 256GB, on the same variant
//
//  Business question : a shopper browsing phones picks colour=Black and
//                     capacity=256GB. Only products that actually have a Black
//                     256GB variant may be shown.
//  Access path      : category slug + status, then a single-element match on
//                     the variants array.
//  Expected output  : 11 documents.
//
//  $elemMatch is load-bearing, not decoration. Without it the two conditions
//  are independent and a product qualifies when a Black variant and a 256GB
//  variant exist separately - as many as 23 products do. experiments/
//  q3_elem_match_trap.js runs the wrong form and prints the difference.
// =============================================================================

load("queries/plan.js");

var wanted = {
    status: "active",
    "attributes.colour": "Black",
    "attributes.capacity": "256GB"
};

// One $elemMatch, so both attribute conditions must hold for the same array
// element. Nested field paths inside $elemMatch refer to fields of the element.
var filter = {
    status: "active",
    "categories.slug": "electronics-phones",
    variants: { $elemMatch: wanted }
};

var pipeline = [
    { $match: filter },
    {
        $project: {
            name: 1,
            brand: 1,
            matched_variants: {
                $filter: {
                    input: "$variants",
                    as: "v",
                    cond: {
                        $and: [
                            { $eq: ["$$v.status", "active"] },
                            { $eq: ["$$v.attributes.colour", "Black"] },
                            { $eq: ["$$v.attributes.capacity", "256GB"] }
                        ]
                    }
                }
            }
        }
    },
    { $sort: { name: 1 } }
];

reportPlan("Q3  attribute filter, same variant", function () {
    return db.catalogue.explain("executionStats").aggregate(pipeline);
});
showResults(db.catalogue.aggregate(pipeline).toArray(), 2);
