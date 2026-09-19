# Security Policy

## Project status

`sqlite.zig` is in **early, active development**. As stated in the README:

> **Do not use this in production or on data you cannot afford to lose.**
> There is no stability guarantee on the file format, the API, or correctness
> of edge cases yet. Back up anything important separately.

Do not store sensitive, irreplaceable, or production data in databases created
by this engine, and do not open untrusted `.db` files with it.

## Supported versions

Only the latest commit on the `main` branch receives security fixes. No
stable release with long-term support exists yet.

## Reporting a vulnerability

- **Do not** open a public issue for a suspected vulnerability.
- Open a [private security advisory](https://github.com/muhammad-fiaz/sqlite.zig/security/advisories/new)
  on GitHub, or contact the maintainer through the contact links on the
  repository profile.
- Include: a description of the issue, steps to reproduce (Zig snippet and
  SQL where applicable), and the Zig version and platform you tested on.

## What to expect

- Acknowledgement of your report as soon as it is reviewed.
- A fix committed to `main` once validated with regression tests
  (`zig build test`). Since there are no versioned releases yet, fixes are
  delivered as source commits only.

## Scope notes

This engine parses and executes SQL and reads binary database files, so
fuzzing findings around the SQL front end, the record/page decoders, and
corrupt-image handling are especially welcome. Please include the crashing
input or file whenever possible.
