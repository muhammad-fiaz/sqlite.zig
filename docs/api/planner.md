# Query Planner API

The query planner optimizes SQL queries for efficient execution.

## Overview

The planner analyzes parsed SQL statements and generates an optimal execution plan by considering available indexes, table statistics, and join strategies.

## Components

| Module | Description |
|--------|-------------|
| `planner` | Main query planning logic |
| `optimizer` | Plan optimization passes |
| `cost` | Cost estimation for plan comparison |

## Planning Process

1. **Parse** — SQL is parsed into an AST
2. **Analyze** — Schema is resolved, table/column references validated
3. **Plan** — Execution plan is generated with candidate strategies
4. **Optimize** — Cost-based optimization selects the best plan
5. **Compile** — Plan is compiled into bytecode for the VM

## Join Strategies

| Strategy | Description |
|----------|-------------|
| Nested Loop | For each row in left, scan right. Simple but can be slow. |
| Index Lookup | Use index on right table for each left row. Fast for selective joins. |
| Hash Join | Build hash table on smaller side, probe with larger. Good for large joins. |

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
var result = try db.exec("EXPLAIN QUERY PLAN SELECT * FROM orders WHERE user_id = 1;");
defer rows.deinit();
```
