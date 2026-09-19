---
title: "Virtual Machine API"
description: "The bytecode virtual machine that executes compiled SQL operations, including the execution flow from SQL string to query results."
---

# Virtual Machine API

The bytecode virtual machine executes compiled SQL operations.

## Overview

The VM takes bytecode programs produced by the compiler and executes them
against the schema, producing query results. These modules are internal:
client code reaches them through `Connection`, not by importing them
directly.

## Components

| Module | Description |
|--------|-------------|
| `vm` | `VirtualMachine` execution loop over a `Program` |
| `compiler` | `Compiler` turning statements into a `Program` |
| `opcode` | `OpCode` instruction set plus `Instruction` / `Program` |

## Execution Flow

```
SQL String → Lexer → Parser → AST → Compiler → Program → VM → Results
```

## Bytecode Opcodes

| Opcode | Description |
|--------|-------------|
| `halt` | Stop execution |
| `gotoOp` / `ifOp` / `ifNotOp` | Jumps and conditional jumps |
| `returnOp` | Return from a subroutine |
| `loadNull` / `loadInteger` / `loadReal` / `loadText` / `loadBlob` | Load constants into registers |
| `move` / `copy` | Move values between registers |
| `add` / `subtract` / `multiply` / `divide` / `remainder` / `concat` | Arithmetic and string concatenation |
| `bitAnd` / `bitOr` / `shiftLeft` / `shiftRight` / `bitNot` | Bitwise operators |
| `eq` / `ne` / `lt` / `le` / `gt` / `ge` | Comparisons |
| `isOp` / `isNotOp` / `isNull` / `notNull` | `IS` / `NULL` tests |
| `openRead` / `openWrite` / `openEphemeral` / `close` | Cursor lifecycle |
| `rewind` / `next` / `prev` | Cursor movement |
| `seekGE` / `seekGT` / `seekLE` / `seekLT` / `seekEQ` | Cursor seeks |
| `column` / `rowid` | Read the current row |
| `makeRecord` / `insert` / `delete` / `newRowid` | Write paths |
| `resultRow` | Emit a result row |
| `function` / `aggStep` / `aggFinal` | Scalar and aggregate evaluation |

Instructions carry `p1`–`p5` operands plus a target register, mirroring the
operand style of SQLite's own VDBE.

## Running the VM

The connection compiles statements with
`Compiler.init(allocator, &store)` and runs them with
`VirtualMachine.init(allocator, &store)` followed by
`execute(&program, columnNames)`. Client code uses `db.exec` instead of
driving these types directly.
