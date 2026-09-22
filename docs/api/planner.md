---
title: "Query Planner API"
description: "Query planner that optimizes SQL statements for efficient execution, including cost-based plan selection and index usage."
---

# Query Planner API

The query planner optimizes SQL queries for efficient execution.

## Overview

The planner analyzes parsed SQL statements and generates an execution plan
by considering available indexes, equality/range constraints, and join
order, with cost estimates comparing candidate plans.

## Components

| Module | Description |
|--------|-------------|
| `planner` | Main query planning logic (access path, index seek, join order) |
| `optimizer` | Constant folding and predicate pushdown checks (source-local tests; not yet wired into `planSelect`) |
| `cost` | Cost estimation for plan comparison |

## Planning Process

1. **Parse** — SQL is parsed into an AST
2. **Analyze** — Schema is resolved, table/column references validated
3. **Plan** — Execution plan is generated with candidate strategies
4. **Optimize** — Cost-based selection picks the best access path; the
   optimizer module provides additional fold/pushdown helpers for future
   integration
5. **Compile** — A parallel bytecode path compiles SELECT programs for the VM;
   the primary interpreter runs statements from the plan and AST

## Join Strategies

| Strategy | Description |
|----------|-------------|
| Nested Loop | For each row in left, scan right. |
| Index Lookup | Use an index on the inner table for each outer row. Fast for selective joins. |

## Index Usage

The planner automatically uses indexes when:

- A column has an index
- The query filters on that column with `=`, `<`, `>`, `<=`, `>=`
- The index covers enough rows to be faster than a full scan

```zig
// This query uses the index on user_id
var result = try db.exec("SELECT * FROM orders WHERE user_id = 1;");
```

## EXPLAIN QUERY PLAN

Inspect the execution plan:

```zig
var plan = try db.exec("EXPLAIN QUERY PLAN SELECT * FROM orders WHERE user_id = 1;");
defer plan.deinit();
```
