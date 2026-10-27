# Portfolio 2 — Query Processing and Optimisation

**Marks:** 7 of 40
**Status:** not started

## Scope

Working against the ShopStack schema from Portfolio 1, this activity covers how the
database executes queries and how that execution is improved.

Planned evidence:

1. **Business queries** — a set of realistic questions (revenue by month and region,
   category performance via a recursive CTE over the category tree, basket analysis,
   stock-out risk, returns rate) with their SQL and results.
2. **Baseline execution plans** — `EXPLAIN (ANALYZE, BUFFERS)` for each query before
   any tuning. Portfolio 1 deliberately ships no secondary indexes, so this baseline is
   an honest sequential-scan starting point.
3. **Index design** — `indexes.sql` adding B-tree, composite and partial indexes, each
   with a stated justification (selectivity, sort avoidance, covering).
4. **Before/after comparison** — the same plans re-captured after indexing, with
   execution time and buffer counts side by side.
5. **Analysis** — which queries improved and why, which did not, and where the planner
   chose a different strategy than expected.

## Planned files

```
queries.sql          the business queries
indexes.sql          index definitions with rationale
plans/before/*.txt   EXPLAIN ANALYZE output, pre-index
plans/after/*.txt    EXPLAIN ANALYZE output, post-index
results/summary.csv  query, plan type, rows, time before/after
README.md            findings and analysis
```
