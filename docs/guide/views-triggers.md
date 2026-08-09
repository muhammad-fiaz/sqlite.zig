---
title: "Views & Triggers"
description: "Creating and using SQL views and triggers with both raw SQL and the typed DSL query builder."
---

# Views & Triggers

## Views

Views are virtual tables defined by a SELECT query.

### Create a View (Raw SQL)

```zig
var result = try db.exec(
    \\CREATE VIEW active_users AS
    \\SELECT id, name FROM users WHERE active = 1
);
result.deinit();
```

### Read from a View

```zig
var rows = try db.exec("SELECT * FROM active_users;");
defer rows.deinit();
```

### Typed DSL with Views

Views can be queried using raw SQL and their results read into typed structures.

## Triggers

Triggers automatically execute SQL in response to INSERT, UPDATE, or DELETE operations.

### BEFORE INSERT Trigger

```zig
var result = try db.exec(
    \\CREATE TRIGGER auto_timestamp
    \\BEFORE INSERT ON orders
    \\BEGIN
    \\  UPDATE orders SET created_at = datetime('now') WHERE id = NEW.id;
    \\END
);
result.deinit();
```

### AFTER DELETE Trigger

```zig
var result = try db.exec(
    \\CREATE TRIGGER cleanup_after_delete
    \\AFTER DELETE ON users
    \\BEGIN
    \\  DELETE FROM orders WHERE user_id = OLD.id;
    \\END
);
result.deinit();
```

### Trigger Events

| Event | Description |
|-------|-------------|
| `BEFORE INSERT` | Fires before a new row is inserted |
| `AFTER INSERT` | Fires after a new row is inserted |
| `BEFORE UPDATE` | Fires before a row is updated |
| `AFTER UPDATE` | Fires after a row is updated |
| `BEFORE DELETE` | Fires before a row is deleted |
| `AFTER DELETE` | Fires after a row is deleted |

### OLD and NEW References

- `NEW.column` — Access the new row value (INSERT/UPDATE)
- `OLD.column` — Access the old row value (UPDATE/DELETE)
