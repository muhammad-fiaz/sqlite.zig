---
title: "Recursive CTEs"
description: "Recursive CTEs for hierarchical tree traversal"
---

# Recursive CTEs

Use recursive CTEs for hierarchical tree traversal.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_32.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS tree_nodes (id INTEGER, name TEXT, parent_id INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO tree_nodes VALUES (1, 'root', NULL), (2, 'child1', 1), (3, 'child2', 1), (4, 'grandchild', 2);");
    result.deinit();
    var rows = try db.exec(
        \\WITH RECURSIVE tree AS (
        \\  SELECT id, name, parent_id, 0 AS depth
        \\  FROM tree_nodes WHERE parent_id IS NULL
        \\  UNION ALL
        \\  SELECT n.id, n.name, n.parent_id, t.depth + 1
        \\  FROM tree_nodes n
        \\  INNER JOIN tree t ON n.parent_id = t.id
        \\)
        \\SELECT * FROM tree ORDER BY depth;
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 4), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-32-recursive-ctes`