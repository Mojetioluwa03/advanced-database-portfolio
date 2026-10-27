// =============================================================================
//  Experiment - would an attribute index serve Q3 better than the category?
//
//  Q3 is anchored on (categories.slug, status), which examines ~337 documents
//  to return 11. The filter itself is an $elemMatch on colour + capacity, so a
//  compound index on those two fields - legal, because both live in the same
//  array - can go straight at the matching elements.
//
//  This experiment builds that index, records what the planner does with it,
//  forces each index with a hint so the comparison is not just the planner's
//  opinion, and then drops it again. The index is NOT part of model/indexes.js;
//  the reason is in the closing lines and in results/experiment-attribute-index.txt.
// =============================================================================

load("queries/plan.js");

var pipeline = [
    {
        $match: {
            status: "active",
            "categories.slug": "electronics-phones",
            variants: {
                $elemMatch: {
                    status: "active",
                    "attributes.colour": "Black",
                    "attributes.capacity": "256GB"
                }
            }
        }
    },
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

function measure(label, hint) {
    var explain = hint
        ? db.catalogue.explain("executionStats").aggregate(pipeline, { hint: hint })
        : db.catalogue.explain("executionStats").aggregate(pipeline);
    var stats = cursorStats(explain);
    var planner = cursorPlanner(explain);
    var ms = stats.executionTimeMillis !== undefined
        ? stats.executionTimeMillis
        : stats.executionTimeMillisEstimate;
    print(label);
    print("    plan         " + planPath(planner.winningPlan));
    print("    keysExamined " + stats.totalKeysExamined + "  docsExamined " + stats.totalDocsExamined +
          "  ms " + ms);
    return { keys: stats.totalKeysExamined, docs: stats.totalDocsExamined };
}

print("A. category index alone");
measure("   (planner)", null);

print("");
print("B. attribute index added");
var created = db.catalogue.createIndex(
    { "variants.attributes.colour": 1, "variants.attributes.capacity": 1 },
    { name: "try_attr_index" }
);
print("   created " + created);
measure("   planner choice", null);
measure("   forced: category index", { "categories.slug": 1, status: 1 });
measure("   forced: attribute index", { "variants.attributes.colour": 1, "variants.attributes.capacity": 1 });

db.catalogue.dropIndex("try_attr_index");
print("");
print("C. attribute index dropped - the plan is back to three indexes");
print("   Not adopted. It examines ~6x fewer documents, but it serves exactly one");
print("   filter shape (colour then capacity, in that order); faceted browsing needs");
print("   an index per facet or a search engine, which is out of scope here.");
