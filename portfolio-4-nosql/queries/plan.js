// =============================================================================
//  plan.js - shared reporting helpers for the five MQL queries.
//
//  Loaded by each queries/qN_*.js file with load("queries/plan.js"), so it runs
//  with the portfolio directory as the working directory:
//
//      cd portfolio-4-nosql && mongosh --port 27018 --quiet --file queries/q1_product_page.js
//
//  Nothing here is a graded query. It only formats explain("executionStats")
//  output so the transcripts in plans/ can be compared line for line between
//  the unindexed and indexed phases. The query under test is always the same
//  object in both the explain call and the result fetch.
// =============================================================================

// explain() on a find returns executionStats at the top level; explain() on an
// aggregate nests it under stages[0].$cursor. Everything in this portfolio's
// pipelines starts with a $match, so the cursor stage is always present.
function cursorStats(explain) {
    if (explain.executionStats) {
        return explain.executionStats;
    }
    var first = explain.stages && explain.stages[0];
    return first && first.$cursor ? first.$cursor.executionStats : null;
}

function cursorPlanner(explain) {
    if (explain.queryPlanner) {
        return explain.queryPlanner;
    }
    var first = explain.stages && explain.stages[0];
    return first && first.$cursor ? first.$cursor.queryPlanner : null;
}

function planPath(stage, depth) {
    if (!stage) {
        return "";
    }
    depth = depth || 0;
    var label = stage.stage + (stage.indexName ? "(" + stage.indexName + ")" : "");
    var kids = stage.inputStages || (stage.inputStage ? [stage.inputStage] : []);
    if (!kids.length || depth >= 6) {
        return label;
    }
    return label + " <- " + kids.map(function (k) { return planPath(k, depth + 1); }).join(" | ");
}

function median(values) {
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    return sorted[Math.floor(sorted.length / 2)];
}

// One discarded run, then three measured runs, exactly as Portfolio 2 measured
// its SQL plans. executionTimeMillis is server-side execution, so the mongosh
// client and the wire do not distort the number.
function reportPlan(title, explainFn) {
    var times = [];
    var stats = null;
    for (var run = 0; run < 4; run++) {
        var explain = explainFn();
        stats = cursorStats(explain);
        var planner = cursorPlanner(explain);
        if (run === 0) {
            print(title);
            print("    plan           " + (planner ? planPath(planner.winningPlan) : "(no cursor stage)"));
        } else {
            times.push(
                stats.executionTimeMillis !== undefined
                    ? stats.executionTimeMillis
                    : stats.executionTimeMillisEstimate
            );
        }
    }
    print("    docsExamined   " + stats.totalDocsExamined);
    print("    keysExamined   " + stats.totalKeysExamined);
    print("    cursorReturned " + stats.nReturned);
    print("    execMs         " + times.join(", ") + "  median " + median(times));
}

function showResults(docs, max) {
    print("    returned       " + docs.length + " document(s)");
    docs.slice(0, max === undefined ? 2 : max).forEach(function (doc) {
        printjson(doc);
    });
    if (docs.length > (max === undefined ? 2 : max)) {
        print("    ... " + (docs.length - (max === undefined ? 2 : max)) + " more");
    }
}
