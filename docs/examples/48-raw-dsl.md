---
title: "48 — Raw DSL"
description: "Schema-less Raw DSL querying with runtime table and column names."
---

# 48 — Raw DSL

The Raw DSL is for existing tables whose schema is not represented by a Zig
struct. It accepts runtime table and column identifiers while preserving the
library's SQL value rendering:

```zig
var rows = try db
    .from("users")
    .where(db.col("age").gte(18))
    .select("id, name")
    .fetchAll();
defer rows.deinit();
```

Run the executable with:

```text
zig build run-48_raw_dsl
```

Typed schemas should use the typed DSL; Raw DSL is intentionally schema-less.




