---
title: "Expression Operators"
description: "Comparison, logical, pattern, string, arithmetic, and predicate operators across Raw, Dynamic, and Typed interfaces."
---

# Expression Operators

Covers every operator from the feature table through one shared engine:

`= == != <> < <= > >=` `AND OR NOT` `LIKE NOT LIKE` `% _ ESCAPE`
`GLOB` `REGEXP` `MATCH` `||` `LOWER UPPER LENGTH SUBSTR REPLACE TRIM LTRIM RTRIM INSTR HEX QUOTE UNICODE CHAR PRINTF`
`IN NOT IN` `BETWEEN NOT BETWEEN` `IS NULL IS NOT NULL` `IS IS NOT IS DISTINCT FROM`
`CASE CAST COLLATE` `+ - * / %` `& | << >> ~` `EXISTS NOT EXISTS`.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | `CREATE TABLE features ...` | Deterministic sample with NULL row |
| 2 | `INSERT` | 4 rows plus NULL edge row, verified by count and storage class |
| 3 | `SELECT WHERE` comparisons | `= == != <> < <= > >= IS IS NOT DISTINCT` |
| 4 | `AND OR NOT` | WHERE combinators plus `NOT (expr)` and expression `AND OR NOT` |
| 5 | `LIKE / GLOB` | `% _ ESCAPE`, `* ? [] [^]`, `NOT LIKE`, `NOT GLOB` |
| 6 | `REGEXP / MATCH` | `^Al`, `^A.*e$`, `NOT REGEXP`, substring `MATCH`, `NOT MATCH` |
| 7 | `||` | Text, integer, and mixed concatenation |
| 8 | String functions | Lower/upper/length/substr/replace/trim/instr/hex/quote/unicode/char/printf |
| 9 | `IN BETWEEN IS NULL CASE CAST COLLATE` | Lists, ranges, NULL, searched/simple CASE, `CAST`, `COLLATE NOCASE` |
| 10 | Arithmetic/bitwise | `+ - * / %`, unary, `& | << >> ~` |
| 11 | `EXISTS` | Correlated existence checks |
| 12 | Dynamic DSL | `like`, `likeEscape`, `glob`, `notGlob`, `regexp`, `matchPattern`, `between`, `isNull`, `collate`, `andWhere`, `orWhere`, `not_()` |
| 13 | Typed DSL | Same predicates via `Feature.columns.*`, plus `schema.validate()` |
| 14 | Cross-interface | Raw insert seen by DSL/typed; DSL/typed inserts seen by raw |
| 15 | Close/reopen | `LIKE`, `REGEXP`, `MATCH` counts survive persistence |

## Source Code

```zig
var dynRegexp = try db.from("features").where(db.col("name").regexp("^Al")).fetch();
var typedMatch = try db.from(Feature).where(Feature.columns.body.matchPattern("sqlite")).fetch();
var collated = try db.exec("SELECT id FROM features WHERE name COLLATE NOCASE = 'alice';");
```

Every mutation is followed by `SELECT` verification. Counts, exact text,
integer storage classes, NULL handling, and ordering are asserted. The
database is closed and reopened and the persisted counts are asserted again.

## Zig Output

```text
53 expression operators: raw/dynamic/typed verified with persistence
```

> [!TIP]
> Run with: `zig build run-53_expression_operators`
