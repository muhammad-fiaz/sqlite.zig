# Installation

## Method 1: Zig Fetch (Recommended)

Add the dependency via `zig fetch`:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/sqlite.zig.git
```

Then in your `build.zig`:

```zig
const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
```

## Method 2: Manual build.zig.zon

Add the dependency to your `build.zig.zon` file:

```zig
.dependencies = .{
    .sqlite = .{
        .url = "https://github.com/muhammad-fiaz/sqlite.zig/archive/refs/heads/main.tar.gz",
        .hash = "...", // Run zig fetch --save <url> to generate
    },
},
```

## Method 3: Local Source Checkout

Clone the repository locally:

```bash
git clone https://github.com/muhammad-fiaz/sqlite.zig.git
cd sqlite.zig
zig build
```

To use a local checkout from another project, add a path dependency:

```zig
.dependencies = .{
    .sqlite = .{
        .path = "../sqlite.zig",
    },
},
```

## Verifying the Installation

After adding the dependency, create a simple test:

```zig
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "test.db");
    defer db.close();
    var result = try db.exec("SELECT 1;");
    result.deinit();
}
```

Run it:

```bash
zig build run
```

> [!TIP]
> Pin to a specific commit or tag rather than tracking `main` directly. The public API can change at any time before a tagged release.
