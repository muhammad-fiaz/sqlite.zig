---
title: "Coverage Matrix"
description: "Honest per-feature status across Raw SQL, Dynamic DSL, and Typed DSL."
---

# Coverage Matrix

Statuses: **Supported** (implemented and tested), **Partial** (works with
documented limits), **Unsupported** (explicit error, not silently faked).

## Statements

| Feature | Raw SQL | Dynamic DSL | Typed DSL | Notes |
|---------|:-------:|:-----------:|:---------:|-------|
| SELECT | Supported | Supported | Supported | One aggregate per non-grouped statement |
| INSERT | Supported | Supported | Supported | |
| UPDATE | Supported | Supported | Supported | |
| DELETE | Supported | Supported | Supported | |
| INSERT OR IGNORE / REPLACE | Supported | Supported | Supported | `insertOrIgnore` / `insertOrReplace` |
| ON CONFLICT DO NOTHING / UPDATE | Supported | Unsupported | Unsupported | Raw SQL escape hatch |
| RETURNING | Unsupported | Unsupported | Unsupported | Explicit error |
| WITH / WITH RECURSIVE | Supported | Supported | Supported | `.with` / `.withRecursive`, raw bodies |
| UNION / INTERSECT / EXCEPT | Unsupported | Unsupported | Unsupported | Except inside recursive CTE bodies |

## Queries

| Feature | Raw SQL | Dynamic DSL | Typed DSL | Notes |
|---------|:-------:|:-----------:|:---------:|-------|
| WHERE / AND / OR | Supported | Supported | Supported | `where` / `andWhere` / `orWhere` |
| IN list / subquery | Supported | Supported | Supported | `whereInValues` / `whereInQuery` |
| NOT IN | Supported | Supported | Supported | NULL semantics per SQLite |
| BETWEEN / NOT BETWEEN | Supported | Supported | Supported | |
| EXISTS / NOT EXISTS | Supported | Supported | Supported | Correlated supported |
| LIKE / NOT LIKE | Supported | Supported | Supported | ASCII case-insensitive |
| GLOB / NOT GLOB | Supported | Supported | Supported | Case-sensitive glob semantics |
| MATCH / REGEXP | Unsupported | Unsupported | Unsupported | No such functions |
| IS / IS NOT / IS NULL | Supported | Supported | Supported | |
| IS DISTINCT FROM | Supported | Supported | Supported | |
| JOIN variants | Supported | Supported | Supported | Expression `ON`, incl. RIGHT/FULL |
| USING / NATURAL | Unsupported | Unsupported | Unsupported | Explicit error |
| Table aliases | Unsupported | Unsupported | Unsupported | Use full table names |
| Derived tables | Unsupported | Unsupported | Unsupported | Use CTEs |
| Scalar subqueries | Unsupported | Unsupported | Unsupported | Use joins or two queries |
| GROUP BY / HAVING | Supported | Supported | Supported | `havingCount` covers `COUNT(*)` |
| ORDER BY / LIMIT / OFFSET | Supported | Supported | Supported | Bare columns; no function ordering |
| DISTINCT | Supported | Supported | Supported | |
| CASE | Unsupported | Unsupported | Unsupported | Explicit error |
| Window functions | Unsupported | Unsupported | Unsupported | Explicit error |

## Functions and aggregates

| Feature | Raw SQL | Dynamic DSL | Typed DSL | Notes |
|---------|:-------:|:-----------:|:---------:|-------|
| COUNT / SUM / AVG / MIN / MAX | Supported | Supported | Supported | Column `.sum()` style + `countStar()` |
| COUNT DISTINCT | Partial | Supported | Supported | DSL only; raw `COUNT(DISTINCT x)` unsupported |
| lower/upper/trim/ltrim/rtrim | Supported | Supported | Supported | Column wrappers, predicates + projections |
| length/abs/round/typeof | Supported | Supported | Supported | `.round(digits)` always takes precision |
| coalesce/ifnull/nullif | Supported | Partial | Partial | `nullif` raw only; wrappers for the rest |
| instr/replace/substr/cast | Supported | Supported | Supported | |
| json_extract / json_set | Supported | Supported | Supported | Top-level scalar keys only |
| Other JSON1 | Unsupported | Unsupported | Unsupported | Explicit error |
| Date/time functions | Unsupported | Unsupported | Unsupported | No date storage class either |
| Math functions | Unsupported | Unsupported | Unsupported | Beyond abs/round |

## Schema

| Feature | Raw SQL | Dynamic DSL | Typed DSL | Notes |
|---------|:-------:|:-----------:|:---------:|-------|
| CREATE / DROP TABLE | Supported | Supported | Supported | |
| ALTER (add/rename/drop) | Supported | Unsupported | Partial | Typed add/rename/drop column helpers |
| PRIMARY KEY / composite | Supported | Supported | Supported | |
| FOREIGN KEY / composite | Supported | Supported | Supported | `.restrict` / `.cascade` / `.setNull` |
| SET DEFAULT / NO ACTION | Unsupported | Unsupported | Unsupported | Parser rejects |
| UNIQUE / composite | Supported | Supported | Supported | |
| NOT NULL / DEFAULT | Supported | Supported | Supported | Zig mapping documented |
| CHECK | Unsupported | Unsupported | Unsupported | Parser rejects |
| Generated columns | Unsupported | Unsupported | Unsupported | Parser rejects |
| STRICT / WITHOUT ROWID | Unsupported | Unsupported | Unsupported | Parser rejects |
| Plain / unique indexes | Supported | Supported | Supported | `createIndex` |
| Partial / expression indexes | Unsupported | Unsupported | Unsupported | Parser rejects |
| Views | Supported | Supported | Supported | Typed reads over views |
| Triggers (AFTER) | Supported | Supported | Supported | Raw DDL; NEW/OLD supported |
| BEFORE triggers | Unsupported | Unsupported | Unsupported | Parser requires AFTER |
| generate_series | Supported | Supported | Supported | Only virtual module |
| Other virtual tables | Unsupported | Unsupported | Unsupported | Explicit error |
| ATTACH / DETACH / VACUUM | Unsupported | Unsupported | Unsupported | Explicit error |

## Transactions and durability

| Feature | Status | Notes |
|---------|:------:|-------|
| BEGIN / COMMIT / ROLLBACK | Supported | Deferred/immediate/exclusive accepted |
| SAVEPOINT / RELEASE / ROLLBACK TO | Supported | Nested savepoints tested |
| Rollback journal | Supported | |
| WAL / checkpoint | Supported | `PRAGMA journal_mode` toggles |
| PRAGMA foreign_keys / user_version / application_id | Supported | Others return explicit errors |

## Values

NULL, INTEGER (i64 incl. boundaries), REAL, TEXT, and BLOB storage work
across insert/update/select/where/join/order/constraints/transactions in all
three modes. Blob literals (`X'..'`) are unsupported; bind blobs through
structured values. Zig mappings: ints/bool to INTEGER, floats to REAL,
`[]const u8` to TEXT, `?T` nullable; oversized unsigned integers fail loudly
instead of truncating.
