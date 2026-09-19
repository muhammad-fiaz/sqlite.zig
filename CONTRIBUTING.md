# Contributing to sqlite.zig

Thank you for considering a contribution. `sqlite.zig` is a native,
zero-dependency SQLite-compatible engine written entirely in Zig.

## Prerequisites

- Zig **0.16.0+** (see [ziglang.org](https://ziglang.org/download/)).
- Windows 10+, Linux, or macOS.
- Git.
- [Bun](https://bun.sh) (only if you work on the documentation website in
  `docs/`).

## Fork and clone for local development

1. Fork the repository on GitHub:
   `https://github.com/muhammad-fiaz/sqlite.zig` (Fork button, top right).
2. Clone your fork locally:

   ```bash
   git clone https://github.com/<your-username>/sqlite.zig.git
   cd sqlite.zig
   ```

3. Track the upstream repository so you can stay in sync:

   ```bash
   git remote add upstream https://github.com/muhammad-fiaz/sqlite.zig.git
   git fetch upstream
   ```

4. Verify the checkout builds and all tests pass:

   ```bash
   zig build
   zig build test
   ```

## Using sqlite.zig as a dependency

The recommended way to depend on `sqlite.zig` from another project is
`zig fetch`:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/sqlite.zig.git
```

Then wire it into your `build.zig`:

```zig
const sqliteDep = b.dependency("sqlite", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sqlite", sqliteDep.module("sqlite"));
```

See the [installation guide](https://muhammad-fiaz.github.io/sqlite.zig/guide/installation)
for the manual `build.zig.zon` and local path-dependency variants.

## Improve and contribute

1. Sync with upstream and create a focused branch:

   ```bash
   git checkout main
   git pull upstream main
   git checkout -b feat/short-description
   ```

2. Make your change. Keep it narrow: one feature or fix per pull request.
   Check open issues first so effort is not duplicated on large changes.

3. Verify before pushing:

   ```bash
   zig fmt .
   zig build test
   zig build examples
   ```

   If you touched the documentation website, also verify it builds:

   ```bash
   cd docs
   bun install
   bun run build
   ```

4. Commit with a concise message, push to your fork, and open a pull
   request against `main` using the provided template:

   ```bash
   git push origin feat/short-description
   ```

## Pull request checklist

- [ ] `zig build test` passes
- [ ] All examples build (`zig build examples`)
- [ ] Docs build (`bun run build` in `docs/`) if docs changed
- [ ] New tests added where applicable
- [ ] `zig fmt .` applied
- [ ] Self-review completed

## Reporting bugs

Use the bug report issue template and include a minimal reproducible test case
(Zig snippet plus SQL). For security-sensitive reports, see `SECURITY.md`.
