# SQLite Test-Family Coverage Matrix

Scope: native Zig engine in `src/` versus the SQLite C reference
(amalgamation family `select.c`, `where.c`, `expr.c`, `func.c`,
`insert.c`, `update.c`, `delete.c`, `trigger.c`, `fkey.c`, `btree.c`,
`pager.c`, `journal.c`, `wal.c`, `vacuum.c`, `analyze.c`, `pragma.c`,
`attach.c`, `window.c`, `parse.y` / `tokenize.c`, `vdbemem.c`, `utf.c`,
`os.c`) and the TCL suites (`select.test`, `where.test`, `expr.test`,
`func.test`, `join.test`, `subquery.test`, `with.test`, `window.test`,
`trigger.test`, `view.test`, `index.test`, `fk.test`,
`transactions.test`, `pager.test`, `wal.test`, `corrupt.test`,
`filefmt.test`, `affinity.test`, `strict.test`, `upsert.test`, etc.).

This project does **not** claim 100% SQLite compatibility. Statuses below
were grounded in `rg` over `src/` (September 2026) and describe the
in-memory engine plus the SQLite file-image reader/writer. There is no
differential harness against SQLite C and no fault-injection runner;
"tests" means source-local `test` blocks (`zig build test`),
`examples/*.zig` behavioural checks, and file-format round-trips.

## Method

1. Enumerated engine entry points with `rg -n "fn "` on
   `src/connection/connection.zig` (300+ functions) and skimmed
   `src/sql/parser.zig`, `src/catalog/schema.zig`,
   `src/storage/sqlite_image.zig`, and `src/dsl/query_builder.zig`
   for coherent responsibilities — without editing those files.
2. Verified each family with targeted `rg` keywords (see Maintenance):
   `generate_series`, `VACUUM`, `REINDEX`, `WITHOUT ROWID`, `STRICT`,
   `window`, `trigger`, `ATTACH`, `DETACH`, `SAVEPOINT`, `journal_mode`,
   `integrity_check`, `foreign_key_check`, `RETURNING`, `upsert`,
   `generated`, `INSTEAD`, `DEFERR`.
3. Mapped every hit to its owning Zig module and to a test location.
   Absence of hits (e.g. `REINDEX`) is reported as `Not Implemented`,
   not papered over.

## Legend

- `Covered` — core family implemented with source-local and/or example
  tests; usable for normal workloads.
- `Partial` — usable subset with documented gaps; check the TODO pointer
  before relying on corners.
- `Not Implemented` — parsed or absent with no engine support.
- `Out of Scope` — deliberately excluded (single-threaded engine, no
  fuzzer, no R-Tree/FTS).

## Matrix

| # | Test family | SQLite reference | Zig modules | Test locations | Status | Remaining TODO |
|---|-------------|------------------|-------------|----------------|--------|----------------|
| 1 | SELECT (projections, DISTINCT, ORDER BY, LIMIT/OFFSET) | `select.c`, `select.test` | `connection/connection.zig` (`select`, `selectJoin`, `selectGrouped`), `plan/planner.zig`, `dsl/query_builder.zig` | source-local tests in `connection.zig`; `examples/04,12,14,16,36,54,63,69` | Covered | `TODO(select)`: `DISTINCT`+`ORDER BY` combos, `LIMIT` in compound arms |
| 2 | WHERE / predicates (comparison, IN, BETWEEN, EXISTS, LIKE/GLOB/REGEXP/MATCH, COLLATE) | `where.c`, `expr.c`, `where.test` | `connection/connection.zig` (`matchesContext`, `evalContext`), `connection/pattern.zig`, `connection/compare.zig`, `vm/value.zig` | `pattern.zig`/`compare.zig` unit tests; `connection.zig` predicate tests; `examples/43,44,45,53` | Covered | `TODO(where)`: three-valued-logic audit, `IS DISTINCT FROM` collation matrix |
| 3 | Expressions (arithmetic, concat, CASE, CAST, parameters) | `expr.c`, `vdbemem.c`, `expr.test` | `sql/expr.zig`, `sql/ast.zig`, `connection/connection.zig` (`evalBinary`, `materialize`) | source-local `sql/expr.zig` tests; `examples/53,58` | Covered | `TODO(expr)`: numeric overflow and `CAST` edge parity vs. SQLite |
| 4 | Scalar / math / datetime / JSON / aggregate functions | `func.c`, `date.c`, `json1.c`, `func.test` | `sql/functions/scalar.zig`, `math.zig`, `datetime.zig`, `json.zig`, `aggregate.zig`, `window.zig` | source-local function tests; `examples/20,36` | Partial | `TODO(func)`: full scalar-surface audit; JSON path and datetime corners |
| 5 | JOINs (INNER/LEFT, USING/NATURAL, multi-key, UPDATE..FROM) | `where.c`, `join.test` | `connection/connection.zig` (`selectJoin`, `updateFrom`, ambiguity checks), `dsl/keys.zig` | `connection.zig` join tests; `examples/11,42,59,60` | Covered | `TODO(join)`: RIGHT/FULL OUTER JOIN unsupported by design |
| 6 | Subqueries (scalar, IN, EXISTS, derived tables) | `select.c`, `subquery.test` | `connection/connection.zig` (`executeWithOuter`, `materializeDerivedTable`), `dsl/ast_builder.zig` | `connection.zig` subquery tests; `examples/25,43,44,45,54,63` | Covered | `TODO(subq)`: correlated-subquery performance, derived-table pushdown |
| 7 | CTEs incl. recursive (`WITH`, `WITH RECURSIVE`, compound) | `select.c`, `with.test` | `connection/connection.zig` (`setupCtes`, `executeWith`, `executeCompound`), `sql/parser.zig` | `connection.zig` CTE tests; `examples/24,29,32,51,61` | Covered | `TODO(cte)`: recursion-depth and cycle diagnostics |
| 8 | Window functions (ROW_NUMBER, RANK, LAG/LEAD, PARTITION BY) | `window.c`, `window.test` | `sql/functions/window.zig`, `dsl/column.zig`, `dsl/ast_builder.zig` | `window.zig` unit tests; `examples/64` | Partial | `TODO(window)`: `ROWS`/`RANGE`/`GROUPS` frames, exclusions, `FILTER` |
| 9 | Triggers (BEFORE/AFTER INSERT/UPDATE/DELETE, WHEN, NEW/OLD) | `trigger.c`, `trigger.test` | `catalog/schema.zig` (`Trigger`), `connection/connection.zig` (`fireTriggers`, `renderTriggerBody`) | `connection.zig` trigger tests; `examples/23,57` | Partial | `TODO(trigger)`: `INSTEAD OF` missing (`ast.zig` notes it); recursion policy |
| 10 | Views (CREATE VIEW, read path, updatable subset) | `select.c`, `view.test` | `catalog/schema.zig` (`View`), `connection/connection.zig` (`createViewCommand`) | `connection.zig` view tests; `examples/22` | Partial | `TODO(view)`: writable views limited to `viewTargetsSingleTable`; `TEMP` scoping |
| 11 | Indexes (UNIQUE, partial, expression, EXPLAIN QUERY PLAN) | `btree.c`, `index.test`, `explain.test` | `catalog/schema.zig` (`Index`), `btree/index_btree.zig`, `plan/planner.zig`, `connection/connection.zig` (`plannedIndices`) | source-local `btree`/`plan` tests; `examples/21,33,68` | Covered | `TODO(index)`: covering-index fast path, multi-index AND/OR planning |
| 12 | Foreign keys (CASCADE/SET NULL/SET DEFAULT/RESTRICT, composite) | `fkey.c`, `fk.test` | `catalog/schema.zig` (FK constraints), `connection/connection.zig` (`apply*Actions`, `pragmaForeignKey*`) | `connection.zig` FK tests; `examples/26,28,31,62` | Partial | `TODO(fk)`: `DEFERRABLE INITIALLY DEFERRED` missing |
| 13 | Transactions and savepoints (BEGIN/COMMIT/ROLLBACK, SAVEPOINT) | `main.c`, `transactions.test` | `connection/connection.zig` (`begin*`, `savepoint*`, statement atomicity), `txn/transaction.zig`, `txn/locking.zig` | `connection.zig` txn tests; `examples/03` | Covered | `TODO(txn)`: `txn/locking.zig` is a stub; writer-contention errors untested |
| 14 | Pager / B-tree (page cache, balancing, cursors) | `pager.c`, `btree.c`, `btree.test`, `pager.test` | `storage/pager.zig`, `btree/btree.zig`, `btree/cursor.zig`, `btree/balance.zig`, `btree/index_btree.zig`, `storage/file.zig` | source-local `btree`/`pager` tests; `examples/07,17` | Partial | `TODO(pager)`: in-memory first; cache-spill, overflow, freelist incomplete |
| 15 | Journal / WAL (rollback journal, WAL apply, checkpoint) | `journal.c`, `wal.c`, `wal.test` | `storage/journal.zig`, `storage/wal.zig`, `storage/file.zig` (`journalMode`, `checkpointWal`) | `journal.zig`/`wal.zig` unit tests; `examples/35` | Partial | `TODO(wal)`: crash-recovery replay and cross-process locking untested |
| 16 | Corruption and integrity (`integrity_check`, `foreign_key_check`) | `pragma.c`, `corrupt.test` | `connection/connection.zig` (`pragmaIntegrityCheck`, `checkStoredImage/Rows`, `compareStoredSchema`) | `connection.zig` integrity tests; `examples/62` | Partial | `TODO(corrupt)`: bit-flip/page-checksum suite missing; `quick_check` parity |
| 17 | File format (DB header, pages, image read/write) | `btree.c`, `os.c`, `filefmt.test` | `format/header.zig`, `format/page.zig`, `storage/image.zig`, `storage/sqlite_image.zig`, `storage/file.zig` | source-local `format` tests; `examples/07,08,17` | Partial | `TODO(filefmt)`: auto-vacuum pages, overflow chains, freelist trunks |
| 18 | Varint / record encoding | `vdbe.c`, `record.test` | `format/varint.zig`, `format/record.zig` | source-local `varint`/`record` tests | Covered | `TODO(codec)`: 9-byte varint and negative-number property tests |
| 19 | Type affinity and collations (NUMERIC/TEXT/BLOB, NOCASE/RTRIM) | `vdbemem.c`, `utf.c`, `affinity.test` | `catalog/type_affinity.zig`, `vm/value.zig`, `connection/compare.zig` | `type_affinity` + `value` + `compare` tests; `examples/47,66` | Covered | `TODO(affinity)`: one consolidated `COLLATE` propagation test |
| 20 | STRICT tables | `table.c`, `strict.test` | `catalog/schema.zig` (`strict`), `connection/connection.zig` (typed create paths) | `connection.zig` strict tests; `examples/66` | Partial | `TODO(strict)`: strict-rejection matrix (INT vs. TEXT corners) |
| 21 | WITHOUT ROWID tables | `btree.c`, `withoutrowid.test` | `catalog/schema.zig` (`withoutRowid`), `storage/sqlite_image.zig` (DDL round-trip) | `connection.zig`/`schema` tests; `examples/67` | Partial | `TODO(worowid)`: PK-as-rowid routing, `rowid` alias errors |
| 22 | Generated columns (STORED recompute, VIRTUAL guards) | `table.c`, `generated.test` | `catalog/schema.zig` (`generatedExpr`), `connection/connection.zig` (`recomputeGeneratedColumns`) | `connection.zig` generated tests; `examples/65` | Partial | `TODO(gencol)`: VIRTUAL-vs-STORED persistence parity |
| 23 | UPSERT (`ON CONFLICT`) and `RETURNING` | `insert.c`, `update.c`, `upsert.test`, `returning.test` | `connection/connection.zig` (`applyUpsert`, `conflictRowTarget`, `evaluateReturning`) | `connection.zig` tests; `examples/38,39,40,41,55,56` | Covered | `TODO(upsert)`: partial-index predicate and `excluded.*` corners |
| 24 | VACUUM (`VACUUM`, `VACUUM INTO`) | `vacuum.c`, `vacuum.test` | `connection/connection.zig` (`vacuumCommand`), `migration/runner.zig` (txn guard) | parser `VACUUM main INTO` tests; command path tests | Partial | `TODO(vacuum)`: `INTO` round-trip test; auto-vacuum stubs |
| 25 | ANALYZE (schema statistics) | `analyze.c`, `analyze.test` | `connection/connection.zig` (`analyzeDatabase*`, `analyzeScope*`) | parser `ANALYZE [target]` tests; scope tests | Partial | `TODO(analyze)`: planner-cost integration unverified |
| 26 | REINDEX | `pragma.c`, `reindex.test` | none (no `rg` hits in `src/`) | none | Not Implemented | `TODO(reindex)`: decide stub versus support |
| 27 | PRAGMA surface (`table_info`, `index_*`, `foreign_key_*`, `database_list`, `journal_mode`, ...) | `pragma.c`, `pragma.test` | `connection/connection.zig` (`executePragma`, `pragma*` helpers), `storage/file.zig` | `connection.zig` pragma tests; `examples/62` | Partial | `TODO(pragma)`: each new pragma needs parser + engine + test trio |
| 28 | ATTACH / DETACH (multi-database routing) | `attach.c`, `attach.test` | `connection/connection.zig` (`attachCommand`, `detachCommand`, `SchemaRef`) | parser `ATTACH`/`DETACH` tests; multi-schema tests | Partial | `TODO(attach)`: cross-DB join/write parity, `TEMP` resolution corners |
| 29 | Fuzz / fault-injection / stress / concurrency | `test/fuzz*.c`, `fault.test`, `thread.test` | none (single-threaded; no harness in `src/`) | smoke via `examples/*` and `zig build test` only | Out of Scope | `TODO(fuzz)`: varint/record property tests first; concurrency stays excluded |

## Notes by area

### Query engine (rows 1–8)

`src/connection/connection.zig` owns execution (`select`, `selectJoin`,
`executeWith`, `executeCompound`, `matchesContext`, `evalContext`,
`evalBinary`), with planning in `plan/planner.zig` and the typed surface in
`src/dsl/`. New stateless helpers live alongside it: `LIKE`/`GLOB`/`REGEXP`/
`MATCH` in `src/connection/pattern.zig` and ordering in
`src/connection/compare.zig` (both registered in `src/sqlite.zig` tests).
`connection.zig` keeps `NULL` propagation, allocation, and I/O; the new
modules must stay dependency-free so a later coordinator pass can rewire
call sites without behaviour drift. Window frames are the largest query
gap: partition/order paths work (`examples/64`), frame clauses do not.

### Schema objects (rows 9–13, 19–23)

`src/catalog/schema.zig` owns `Table`/`Index`/`View`/`Trigger` records plus
`strict`, `withoutRowid`, and `generatedExpr` flags; `src/sql/parser.zig`
owns DDL parsing (`CREATE`, `ALTER`, `ATTACH`, `VACUUM`, `ANALYZE`,
`PRAGMA`). Documented gaps are load-bearing: no `INSTEAD OF` triggers
(`src/sql/ast.zig`), no `DEFERRABLE` FKs, writable views limited to
`viewTargetsSingleTable`, and `txn/locking.zig` as a stub. `UPSERT` and
`RETURNING` are the most complete recent features
(`examples/38–41,55,56`).

### Storage engine (rows 14–18)

The codec layer (`format/varint.zig`, `format/record.zig`,
`format/header.zig`, `format/page.zig`) is the best-tested part of storage.
Above it, `btree/`, `storage/pager.zig`, `storage/journal.zig`,
`storage/wal.zig`, and `storage/file.zig` provide persistence with an
in-memory-first design: `wal.apply` is image-level, checkpoint and
`journal_mode` switching work (`examples/35`), but cache-spill, overflow
chains, freelist trunks, and crash-recovery replay are unverified.

### Admin surface (rows 24–28)

`executePragma` covers the inspection subset (`table_info`/`xinfo`,
`index_list`, `index_info`/`xinfo`, `foreign_key_list`, `database_list`,
`table_list`, `integrity_check`, `foreign_key_check`, `journal_mode`)
with per-schema scoping (`examples/62`). `VACUUM`/`ANALYZE`/`ATTACH`/
`DETACH` parse and execute on the happy path; `REINDEX` has zero `src/`
hits and is `Not Implemented`. `generate_series` is the only virtual
table (`examples/34`).

### Assurance (row 29)

There is no differential runner versus SQLite C, no fault-injection
harness, and no stress/concurrency suite. The engine is single-threaded
by design. Assurance today is source-local `test` blocks plus the
`examples/` behavioural suite and hostile-open tests in `connection.zig`
(`open failure ... instead of crashing`). Any future `fuzz/` work should
start with varint/record property tests, then page-image hostile inputs.

## Test layers used above

- Source-local: `test` blocks at the bottom of each `src/**/*.zig`
  module, run via `zig build test` through `src/sqlite.zig`.
- Behavioural: `examples/01–70` (joins, CTEs, FK actions, window DSL,
  strict/without-rowid, partial/expression indexes, pragma checks).
- Interop: SQLite file-image round-trip (`storage/sqlite_image.zig`,
  `examples/07,08,17`); no C-link interop tests exist.

## Honesty statement

Eleven of twenty-nine families are `Covered`; fifteen are `Partial`; one
(`REINDEX`) is `Not Implemented`; one (fuzz/fault/stress/concurrency) is
`Out of Scope`. Do not present this engine as a drop-in SQLite
replacement: the storage and admin gaps above affect durability and
compatibility claims directly.

## Evidence log (September 2026)

All statuses above were set from these `rg` probes, re-runnable offline:

- `rg -n "fn " src/connection/connection.zig` — 300+ functions; the
  `likeMatchEscape` / `globMatch` / `RegexEngine` / `matchContains` /
  `compareCollated` / `sameValue` / `rowsEqual` / `compareRowsByKeys`
  bodies are the extraction source for `pattern.zig` and `compare.zig`.
- `rg -n "reindex|REINDEX" src` — zero hits, hence row 26 `Not Implemented`.
- `rg -n "instead|INSTEAD" src` — only comments plus `ast.zig` noting
  "no INSTEAD OF here yet", hence row 9 `Partial`.
- `rg -n "deferr|DEFERR" src` — only the `deferred` transaction word,
  hence row 12 `Partial` (no deferrable FKs).
- `rg -n "VACUUM|REINDEX|ANALYZE|PRAGMA|ATTACH|DETACH" src/sql/parser.zig`
  — parser tests exist for `ANALYZE`, `ATTACH`, `DETACH`, and
  `VACUUM main INTO`, backing rows 24, 25, 27, 28.
- `rg -n "generate_series|WITHOUT ROWID|STRICT|window|trigger" src` —
  `generate_series` gated in `schema.zig`, `strict`/`withoutRowid` flags
  plumbed through typed and dynamic create paths, window builders in
  `dsl/column.zig`, trigger stack in `connection.zig`.
- `rg -n "integrity_check|foreign_key_check" src` — `pragmaIntegrityCheck`
  (`checkStoredImage/Rows`, `compareStoredSchema`) and
  `pragmaForeignKeyCheck` in `connection.zig`, backing row 16.
- `rg -n "differential|interop" src docs README.md` — no differential
  runner; interop is file-image round-trip plus `examples/`, hence the
  Assurance section above.

## How to maintain this matrix

- Verify statuses with `rg -n "<keyword>" src` before flipping `Partial`
  to `Covered` (keywords: `generate_series`, `VACUUM`, `REINDEX`,
  `WITHOUT ROWID`, `STRICT`, `window`, `trigger`, `ATTACH`, `DETACH`,
  `SAVEPOINT`, `journal_mode`, `integrity_check`, `foreign_key_check`,
  `RETURNING`, `upsert`, `generated`, `INSTEAD`, `DEFERR`).
- New pure helpers belong in `src/connection/pattern.zig` (string
  predicates) and `src/connection/compare.zig` (`CompareOp` ordering);
  `connection.zig` keeps `NULL` propagation, allocation, and I/O.
- `src/catalog/column_def.zig` was deliberately **not** created: column
  canonicalisation already lives in `catalog/schema.zig` and
  `catalog/type_affinity.zig`. The obsolete `catalog/table_def.zig` and
  `catalog/index_def.zig` duplicates were removed; the canonical `Table` /
  `Index` types live in `catalog/schema.zig` and the parser AST
  (`sql/ast.IndexDef`).
- Interop today is file-image round-trip plus `generate_series` and the
  `examples/` suite — not a differential runner versus SQLite C.
