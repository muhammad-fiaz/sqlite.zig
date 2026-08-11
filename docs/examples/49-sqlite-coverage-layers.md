# SQLite Coverage Layers

This example demonstrates the three supported access layers:

- Raw SQL through `db.exec(...)`, which is the unrestricted SQLite escape hatch.
- RAW DSL through `db.from(...)` and runtime columns from `db.col(...)`.
- Typed Zig-first DSL through a schema type and checked columns.

```sh
zig build run-49_sqlite_coverage_layers
```



