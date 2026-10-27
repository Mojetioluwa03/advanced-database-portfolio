// =============================================================================
//  Q2 - Category browse: one leaf category, price band, cheapest first
//
//  Business question : /c/electronics-audio, filtered to GBP 20-200 and sorted
//                     cheapest first, 20 products per page.
//  Access path      : equality on the embedded category slug (+ status), then
//                     the price band is evaluated over each document's variants.
//  Expected output  : 20 documents.
//
//  Two things the document shape forces here:
//
//  * "Price" is per variant, so the browse price has to be computed - $min over
//    the active variants - before it can be filtered or sorted. In SQL that is
//    a GROUP BY with HAVING; here it is a $set.
//  * The compound index {categories.slug, status} can only bound the category.
//    It cannot also bound variants.price, because MongoDB will not build a
//    compound index over two array fields ("cannot index parallel arrays").
//    So the price band is a residual filter over the 1/8 of documents that the
//    category selects. model/indexes.js records that trade-off.
// =============================================================================

load("queries/plan.js");

var page = { size: 20, number: 0 };

var pipeline = [
    { $match: { "categories.slug": "electronics-audio", status: "active" } },
    {
        $set: {
            active_variants: {
                $filter: { input: "$variants", cond: { $eq: ["$$this.status", "active"] } }
            }
        }
    },
    {
        $set: {
            from_price: { $min: "$active_variants.price" },
            buyable: { $size: "$active_variants" }
        }
    },
    {
        $match: {
            from_price: { $gte: NumberDecimal("20.00"), $lte: NumberDecimal("200.00") }
        }
    },
    { $sort: { from_price: 1, _id: 1 } },
    { $skip: page.size * page.number },
    { $limit: page.size },
    {
        $project: {
            name: 1,
            brand: 1,
            from_price: 1,
            buyable: 1,
            categories: 1
        }
    }
];

reportPlan("Q2  category browse, price band, page 1", function () {
    return db.catalogue.explain("executionStats").aggregate(pipeline);
});
showResults(db.catalogue.aggregate(pipeline).toArray(), 2);
