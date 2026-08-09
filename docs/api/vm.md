---
title: "Virtual Machine API"
description: "The bytecode virtual machine that executes compiled SQL operations, including the execution flow from SQL string to query results."
---

# Virtual Machine API

The bytecode virtual machine executes compiled SQL operations.

## Overview

The VM takes bytecode programs produced by the compiler and executes them against the storage engine, producing query results.

## Components

| Module | Description |
|--------|-------------|
| `vm` | Main VM execution loop |
| `compiler` | Compiles AST/plan to bytecode |
| `opcode` | Bytecode instruction definitions |

## Execution Flow

```
SQL String → Lexer → Parser → AST → Compiler → Bytecode → VM → Results
```

## Bytecode Opcodes

| Opcode | Description |
|--------|-------------|
| `Open` | Open a B-tree cursor on a table or index |
| `Rewind` | Move cursor to first row |
| `Next` | Move cursor to next row |
| `Column` | Extract column value from current row |
| `ResultRow` | Return a row of results |
| `Insert` | Insert a new row |
| `Update` | Update current row |
| `Delete` | Delete current row |
| `Eq` | Compare for equality, jump if false |
| `Ne` | Compare for not-equal, jump if false |
| `Lt` / `Gt` | Comparison operators |
| `Goto` | Unconditional jump |
| `Halt` | Stop execution |
| `Transaction` | Begin a transaction |
| `CreateBtree` | Create a new B-tree |
| `Parse` | Parse SQL inline (for triggers) |

## Running the VM

```zig
const vm = @import("vm");

var machine = vm.VM.init(allocator, &connection);
const result = try machine.execute(bytecode);
```

## Example Bytecode

For `SELECT id, name FROM users WHERE id = 1`:

```
Open 0 users
Rewind 0 -> End
  Column 0 0        # id
  Column 0 1        # name
  ResultRow 2
  Next 0 -> End
Halt
```
