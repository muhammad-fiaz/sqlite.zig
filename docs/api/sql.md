---
title: "SQL API"
description: "Parsing and executing raw SQL strings, including the lexer, parser, AST, and compiler for SQL statements."
---

# SQL API

The SQL module handles parsing and executing raw SQL strings.

## Lexer

Tokenizes SQL input into tokens:

```zig
const lexer = @import("lexer");

var lex = lexer.Lexer.init(allocator, "SELECT * FROM users;");
const tokens = try lex.tokenize();
```

## Parser

Parses tokens into an AST:

```zig
const parser = @import("parser");

var p = parser.Parser.init(allocator, tokens);
const statement = try p.parse();
```

## AST (Abstract Syntax Tree)

The parsed representation of SQL statements:

```zig
const ast = @import("ast");

// Statement types
switch (statement) {
    .create_table => |ct| { /* ... */ },
    .insert => |ins| { /* ... */ },
    .select => |sel| { /* ... */ },
    .update => |upd| { /* ... */ },
    .delete => |del| { /* ... */ },
    .begin => { /* ... */ },
    .commit => { /* ... */ },
    .rollback => { /* ... */ },
    // ...
}
```

## Compiler

Compiles AST into bytecode for the VM:

```zig
const compiler = @import("compiler");

var comp = compiler.Compiler.init(allocator);
const bytecode = try comp.compile(statement);
```

## Virtual Machine

Executes bytecode against the storage engine:

```zig
const vm = @import("vm");

var machine = vm.VM.init(allocator, &connection);
const result = try machine.execute(bytecode);
```

## Supported SQL

See the [SQL Engine](/guide/sql-engine) guide for the full list of supported SQL statements and syntax.
