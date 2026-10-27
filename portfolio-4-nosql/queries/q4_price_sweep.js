// =============================================================================
//  Q4 - Clearance sweep: every product with an active variant under GBP 20
//
//  Business question : which products have a buyable variant below 20, and
//                     which variant is that? Feeds the "under 20" rail.
//  Access path      : range predicate on the embedded variants.price, across
//                     the whole catalogue - the one query here that is not
//                     anchored to a category.
//  Expected output  : 199 documents.
//
//  This is the query the aggregate design makes awkward. The unit of atomicity
//  is the whole product, so a filter on a variant's price has to be written as
//  $elemMatch and the matching variants projected out afterwards with $filter;
//  in SQL it is a plain join predicate on product_variant. What it buys is that
//  the returned document already contains the variant rows, with no second read.
// =============================================================================

load("queries/plan.js");

var cheap = { status: "active", price: { $lt: NumberDecimal("20.00") } };

var pipeline = [
    {
        $match: {
            status: "active",
            variants: { $elemMatch: cheap }
        }
    },
    {
        $project: {
            name: 1,
            brand: 1,
            cheap_variants: {
                $filter: {
                    input: "$variants",
                    as: "v",
                    cond: {
                        $and: [
                            { $eq: ["$$v.status", "active"] },
                            { $lt: ["$$v.price", NumberDecimal("20.00")] }
                        ]
                    }
                }
            }
        }
    },
    { $sort: { _id: 1 } },
    { $limit: 200 }
];

reportPlan("Q4  clearance sweep under GBP 20", function () {
    return db.catalogue.explain("executionStats").aggregate(pipeline);
});
showResults(db.catalogue.aggregate(pipeline).toArray(), 2);
