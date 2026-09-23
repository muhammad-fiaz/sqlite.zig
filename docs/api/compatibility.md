---
title: "Compatibility Matrix"
description: "SQLite test-family coverage matrix mapping SQLite implementation areas to native Zig modules, tests, and support status."
---

# SQLite Compatibility Matrix

| Status | Meaning |
|---|---|
| Supported | Implemented and tested; usable for normal workloads |
| Partial | Usable subset with documented gaps; read Notes before relying on corners |
| TODO | In scope with no implementation yet; planned |
| Limited | Intentionally restricted scope |
| Out of Scope | Deliberately excluded |

| # | Topic | Status | Implementation | Notes |
|---|---|---|---|---|
| 1 | SELECT (projections, DISTINCT, ORDER BY, LIMIT/OFFSET) | Supported | `connection.zig` (`select`, `selectJoin`, `selectGrouped`), `plan/planner.zig`, `dsl/query_builder.zig`; `connection.zig` tests; `examples/04,12,14,16,36,54,63,69` | `DISTINCT`+`ORDER BY`, per-arm/outer compound `LIMIT`, FROM-less `ORDER BY` validation verified |
| 2 | WHERE / predicates (comparison, IN, BETWEEN, EXISTS, LIKE/GLOB/REGEXP/MATCH, COLLATE) | Supported | `connection.zig` (`matchesContext`, `evalContext`), `connection/pattern.zig`, `connection/compare.zig`, `vm/value.zig`; unit + probe tests; `examples/43,44,45,53` | Explicit `COLLATE` propagates; `RTRIM` and outer `(a = b) COLLATE` wrappers honored; `LIKE` ignores explicit `COLLATE` per the reference |
| 3 | Expressions (arithmetic, concat, CASE, CAST, parameters) | Supported | `sql/expr.zig`, `sql/ast.zig`, `connection.zig` (`evalBinary`, `materialize`); `expr.zig` tests; cast/overflow probes; `examples/53,58` | Overflow widening, text/numeric/BLOB `CAST` edges, expression `BETWEEN` verified |
| 4 | Scalar / math / datetime / JSON / aggregate functions | Partial | `sql/functions/{scalar,math,datetime,json,aggregate,window}.zig`; source-local tests; scalar-gap test; `examples/20,36` | `TODO(func)`: older JSON entry points keep text-only inputs; `json_mergepatch`, `json_array_insert`, `json_error_position` unevaluated |
| 5 | JOINs (INNER/LEFT/RIGHT/FULL, USING/NATURAL, multi-key, UPDATE..FROM) | Supported | `connection.zig` (`selectJoin`, `updateFrom`, ambiguity checks), `dsl/keys.zig`; join tests; `examples/11,42,59,60` | `TODO(join)`: correlated join performance |
| 6 | Subqueries (scalar, IN, EXISTS, derived tables) | Supported | `connection.zig` (`executeWithOuter`, `materializeDerivedTable`), `dsl/ast_builder.zig`; subquery tests; `examples/25,43,44,45,54,63` | `TODO(subq)`: correlated-subquery performance, derived-table pushdown |
| 7 | CTEs incl. recursive (`WITH`, `WITH RECURSIVE`, compound) | Supported | `connection.zig` (`setupCtes`, `executeWith`, `executeCompound`), `sql/parser.zig`; CTE tests; `examples/24,29,32,51,61` | `TODO(cte)`: recursion-depth and cycle diagnostics |
| 8 | Window functions (ROW_NUMBER, RANK, LAG/LEAD, PARTITION BY, frames) | Supported | `sql/functions/window.zig`, `sql/parser.zig`, `dsl/column.zig`, `dsl/ast_builder.zig`; unit + parser + frame tests; `examples/64` | `EXCLUDE CURRENT ROW`/`GROUP`/`TIES`, value-scan `RANGE`, `GROUPS` frames verified |
| 9 | Triggers (BEFORE/AFTER/INSTEAD OF, WHEN, NEW/OLD) | Partial | `catalog/schema.zig` (`Trigger`), `connection.zig` (`fireTriggers`, `runTriggerBody` with step budget); trigger tests; `examples/23,57` | `TODO(trigger)`: recursion policy; `UPDATE..FROM` on views unsupported; oversized bodies fail at fire time, not at `CREATE` |
| 10 | Views (CREATE VIEW, read path, updatable subset) | Partial | `catalog/schema.zig` (`View`), `connection.zig` (`createViewCommand`); view tests; `examples/22` | `TODO(view)`: writable views limited to `viewTargetsSingleTable`; `TEMP` scoping |
| 11 | Indexes (UNIQUE, partial, expression, EXPLAIN QUERY PLAN) | Supported | `catalog/schema.zig` (`Index`), `storage/sqlite_image.zig`, `plan/planner.zig`, `connection.zig` (`plannedIndices`); `plan` tests; `examples/21,33,68` | `TODO(index)`: covering-index fast path, multi-index AND/OR planning |
| 12 | Foreign keys (single/composite/self/multi, all actions, DEFERRABLE) | Supported | `catalog/schema.zig`, `connection.zig` (`apply*Actions`, `pragmaForeignKey*`), `connection/fk_actions.zig`; FK + deferrable tests; `examples/26,28,31,62,74` | Immediate, `INITIALLY DEFERRED/IMMEDIATE`, and `defer_foreign_keys` verified; relationships never inferred from names |
| 13 | Transactions and savepoints (BEGIN/COMMIT/ROLLBACK, SAVEPOINT) | Supported | `connection.zig` (`begin*`, `savepoint*`, statement atomicity), `txn/transaction.zig`, `txn/locking.zig`; txn tests; `examples/03` | `TODO(txn)`: cross-process lock coordination untested |
| 14 | Pager / B-tree (page cache, balancing, cursors) | Partial | `storage/pager.zig`, `btree/{btree,cursor,balance}.zig`, `storage/file.zig`; randomized workload + seek probes; `examples/07,17` | `TODO(pager)`: in-memory first; cache-spill, overflow, freelist incomplete |
| 15 | Journal / WAL (header codecs, apply, checkpoint) | Partial | `storage/{journal,wal,file}.zig`; codec unit tests; `examples/35` | `TODO(wal)`: no page-record journal writes yet; crash-recovery replay and cross-process locking untested |
| 16 | Corruption and integrity (`integrity_check`, `foreign_key_check`) | Partial | `connection.zig` (`pragmaIntegrityCheck`, `checkStoredImage/Rows`); integrity tests; `examples/62` | `TODO(corrupt)`: bit-flip/page-checksum suite missing; `quick_check` parity |
| 17 | File format (DB header, pages, image read/write, 64K pages) | Partial | `format/{header,page,record,varint}.zig`, `storage/{image,sqlite_image,file}.zig`; codec + round-trip tests; `examples/07,08,17` | `TODO(filefmt)`: auto-vacuum pages, overflow chains, freelist trunks |
| 18 | Varint / record encoding | Supported | `format/varint.zig`, `format/record.zig`; 4096-value + 512-row seeded sweeps, 9-byte extremes, short-buffer errors | Minimal re-encode and exact decode round-trips verified |
| 19 | Type affinity and collations | Supported | `catalog/type_affinity.zig`, `vm/value.zig` (2048-pair order sweep), `connection/compare.zig`; consolidated `COLLATE` sweep; `examples/47,66` | Total-order properties (reflexivity, antisymmetry) verified |
| 20 | STRICT tables | Partial | `catalog/{schema,strict}.zig`, `sql/coerce.zig`, typed create paths; coercion tests; `examples/66` | `TODO(strict)`: VIRTUAL generated columns skip the check in the reference (`OP_TypeCheck`); affinity matrix verified |
| 21 | WITHOUT ROWID tables | Supported | `catalog/schema.zig`, `storage/sqlite_image.zig`, `plan/planner.zig`; PK routing + alias-error + composite probes; `examples/67` | Single/composite/scan `EXPLAIN` text verified |
| 22 | Generated columns (STORED recompute, VIRTUAL guards) | Partial | `catalog/schema.zig` (`generatedExpr`), `connection.zig` (`recomputeGeneratedColumns`); generated tests; `examples/65` | `TODO(gencol)`: VIRTUAL-vs-STORED persistence parity |
| 23 | UPSERT (`ON CONFLICT`) and `RETURNING` | Supported | `connection.zig` (`applyUpsert`, `conflictRowTarget`, `evaluateReturning`), `connection/conflicts.zig`; partial-index inference tests; `examples/38,39,40,41,55,56` | Target inference, partial-index `WHERE` rule, `excluded.*` corners verified |
| 24 | VACUUM (`VACUUM`, `VACUUM INTO`) | Partial | `connection.zig` (`vacuumCommand`), `migration/runner.zig` (txn guard); parser + command tests | `TODO(vacuum)`: auto-vacuum stubs |
| 25 | ANALYZE (schema statistics) | Partial | `connection.zig` (`analyzeDatabase*`, `analyzeScope*`); parser + scope + planner stats tests | `TODO(analyze)`: histogram and multi-column stats not yet collected |
| 26 | REINDEX (table/index/database/schema targets) | Supported | `connection.zig` (`analyzeTarget`), `sql/parser.zig`, `sql/ast.zig`; parser + engine tests | All target forms verified |
| 27 | PRAGMA surface (`table_info`, `index_*`, `foreign_key_*`, `database_list`, `journal_mode`, ...) | Partial | `connection.zig` (`executePragma`, `pragma*` helpers), `storage/file.zig`; pragma tests; `examples/62` | `TODO(pragma)`: each new pragma needs parser + engine + test trio |
| 28 | ATTACH / DETACH (multi-database routing) | Partial | `connection.zig` (`attachCommand`, `detachCommand`, `SchemaRef`); parser + multi-schema tests | `TODO(attach)`: cross-DB join/write parity, `TEMP` resolution corners |
| 29 | DSL scope convergence (scoped `.id`, `Table.id`, aliases, dynamic, `.all()`) | Supported | `dsl/scope.zig` (single resolver), `dsl/keys.zig`, `dsl/table.zig`, `dsl/query_builder.zig`; equivalence + expansion tests; `examples/15,48,50,52,70,72,73,74` | Bare/explicit forms normalize identically; foreign-scope `all()` expands to qualified references; predicates name their table (Zig forbids operators on bare literals) |
| 30 | AUTOINCREMENT / rowid / `sqlite_sequence` | Supported | `catalog/{schema,sequence}.zig`; sequence unit tests; autoincrement probes | Explicit/omitted/rollback/delete-reinsert generation verified |
| 31 | Limits / budgets (fail closed with `SqlTooBig`) | Supported | `sql/limits.zig` (shared table incl. 64K pages, trigger-step budget); pin tests; budget tests | Parser depth 200 and trigger depth 64 are deliberate stack-safety deviations from SQLite defaults (2500/1000); trigger-step budget enforced at fire time |
| 32 | Virtual tables (`generate_series` only) | Limited | `catalog/schema.zig` (`createVirtualTable`); `examples/34` | Only this module; no general vtab/FTS/R-tree support |
| 33 | Locking / busy behavior | Limited | `txn/{locking,transaction}.zig` + connection txn state; `examples/03,35` | Single-threaded engine; cross-process coordination untested |
| 34 | Fuzz / fault-injection / stress / concurrency | Out of Scope | None (no harness in `src/`) | Smoke via `examples/*` and `zig build test` only; start future fuzz with varint/record property tests |

| Status | Count |
|---|---|
| Supported | 18 |
| Partial | 13 |
| TODO | 0 |
| Limited | 2 |
| Out of Scope | 1 |

| Gate | Command |
|---|---|
| Format | `zig fmt .` |
| Build | `zig build` |
| Tests | `zig build test` (581 tests) |
| Check | `zig build check` |
| Examples | `zig build run-all-examples` (all 74 examples) |

| Rule | Detail |
|---|---|
| Flipping Partial to Supported | Confirm engine, parser, and tests all cover the family first |
| New string predicates | Belong in `src/connection/pattern.zig`; ordering helpers in `src/connection/compare.zig` |
| Verification keywords | `VACUUM`, `STRICT`, `SAVEPOINT`, `journal_mode`, `RETURNING`, `upsert`, `generated`, `INSTEAD`, `DEFERR` must find both implementation and tests |
