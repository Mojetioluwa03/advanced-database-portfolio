// =============================================================================
//  Q5 - Brand league table: products and price spread per brand, top 10
//
//  Business question : which brands carry the most active products, and where
//                     does each one sit on price? Feeds the brands landing page
//                     and the buying team's range review.
//  Access path      : no useful index. $group cannot use one - MongoDB has no
//                     loose index scan - so this is a collection scan plus an
//                     in-memory hash aggregation over 21.5k unwound variants.
//  Expected output  : 10 documents.
//
//  The brand name is embedded in each product, so there is no join. In SQL the
//  same report joins brand purely to get a name; here the join was paid for at
//  write time instead (see model/catalogue.md, "what embedding costs").
// =============================================================================

load("queries/plan.js");

var pipeline = [
    { $match: { status: "active" } },
    { $unwind: "$variants" },
    { $match: { "variants.status": "active" } },
    {
        $group: {
            _id: "$brand.name",
            brand_id: { $first: "$brand.brand_id" },
            product_ids: { $addToSet: "$_id" },
            variants: { $sum: 1 },
            min_price: { $min: "$variants.price" },
            max_price: { $max: "$variants.price" },
            // Averaging is done in double precision on purpose: the result is a
            // reported statistic, not money that anyone is charged, and
            // Decimal128 averages print 25 decimal places.
            avg_price: { $avg: { $toDouble: "$variants.price" } }
        }
    },
    { $set: { products: { $size: "$product_ids" } } },
    { $set: { avg_price: { $round: ["$avg_price", 2] } } },
    { $unset: "product_ids" },
    { $sort: { products: -1, _id: 1 } },
    { $limit: 10 }
];

reportPlan("Q5  brand league table", function () {
    return db.catalogue.explain("executionStats").aggregate(pipeline);
});
showResults(db.catalogue.aggregate(pipeline).toArray(), 10);
