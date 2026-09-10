# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`zigroot` is a whole-project reachability analyzer built on top of
[ZLint](https://github.com/DonIsaac/zlint)'s per-file `Semantic` layer.
ZLint's semantic analysis only understands one file at a time; `zigroot`
adds the project layer above it: file discovery, `@import("*.zig")`
resolution, and cross-file declaration reachability, so dead code that's
only reachable within a cycle of files (not just within one file) can be
found. It reports orphan files (`.zig` files no root reaches) and dead
symbols (declarations no root's reachability BFS reaches).

The README's "Status" section and `issues/*.md` are the living design log
— read them before changing `src/*.zig` to understand what's
implemented, what's an intentional gap, and the likely shape of planned
fixes. Each `issues/NN-*.md` is a single known gap with a measured/example
repro and a sketch of the fix. **When a fix lands that closes an issue,
delete its `issues/NN-*.md` file in the same change** — don't leave closed
tickets sitting in the directory, and don't just mark them done in place.

## Commands

```sh
zig build --fetch   # first time only, fetches ZLint via the package manager
zig build test      # run the whole test suite
zig build            # build zig-out/bin/zigroot
zig build run -- --root src/root.zig --dir src   # build+run with args
```

Requires Zig 0.15.x — ZLint is pinned to a pre-0.16 commit (see
`build.zig.zon`) because its `main` branch moved to 0.16's `Io`-threaded
filesystem API. Re-evaluate that pin before adding new ZLint-derived code.

There's no dedicated single-test filter wired up in `build.zig`; run the
full `zig build test` (it's fast — the corpus is this repo's own small
`src/` tree plus synthetic fixtures inline in each `*_test.zig`).

Run zigroot on itself:
```sh
zig-out/bin/zigroot --root src/root.zig --root src/main.zig --dir src
```
Or against the ZLint dependency for a bigger real-world corpus (see any
issue file's "Measured impact" section for the exact invocation pattern).

Exits non-zero if any orphan files are found.

## Architecture

Everything is layered on ZLint's per-file `Semantic`:

- `File` (`src/File.zig`) parses one file and owns its ZLint
  `Semantic`, plus a derived `OwnerMap` and `SymbolGraph` built alongside it.
- `Project` (`src/Project.zig`) loads root files, follows
  `@import("*.zig")` transitively via `ImportGraph`, and holds all `File`s.
  Any `.zig` file under `--dir` that no root's import graph reaches is an
  orphan file.
- `SymbolId` (`src/SymbolId.zig`) pairs a ZLint `Symbol.Id` with
  its owning `FileId` — the project-wide symbol identity everything else
  is keyed on.
- `OwnerMap` (`src/OwnerMap.zig`) maps every AST node to the
  declaration (symbol) whose body contains it, derived from ZLint's
  per-node parent links.
- `SymbolGraph` (`src/SymbolGraph.zig`) is the same-file
  `Symbol -> Symbol` reference graph: for every symbol, its already-resolved
  incoming references are mapped through `OwnerMap` to find the referencing
  symbol.
- `Resolver` (`src/Resolver.zig`) extends `SymbolGraph` across
  `@import` boundaries — e.g. `storage.start()` where `storage` is an
  import binding — by matching member-access references against the
  target file's exported symbols. `FieldChain.zig` and `DynamicField.zig`
  layer static (`Foo.bar()`, `Outer.Inner.run()`) and dynamic
  (`@field(x, "name")`) member-chain resolution on top, both same-file and
  cross-file. `InstanceType.zig` adds a further layer: resolving a
  variable's syntactically-declared type (`var s: Foo = ...`) to that
  type's symbol so instance-method calls chain the same way static calls
  do. None of this is real type inference — it's reading what's already
  spelled out in the AST.
- `BuildGraph` (`src/BuildGraph.zig`) is a syntactic scan of a
  `build.zig`'s local module graph (`b.createModule` +
  `.addImport("name", ...)`), so named-module imports like
  `@import("storage")` resolve to a file instead of staying unresolved.
  Enabled with `--build-zig <path>`; `b.dependency(...)` modules aren't
  backed by a local file and stay unresolved.
- `Roots` (`src/Roots.zig`) computes automatic reachability roots:
  each root file's `main`, every `export`ed symbol, every symbol
  referenced from a `test { ... }` block (ZLint gives `test` blocks no
  symbol identity of their own), and — under `--library` — every `pub`
  symbol.
- `Reachability` (`src/Reachability.zig`) is a BFS over
  `SymbolGraph` + `Resolver`'s cross-file edges starting from `Roots`;
  `deadSymbols` is everything the BFS never reaches. `extern` declarations
  are excluded since their implementation lives outside the project.
- `Scc` (`src/Scc.zig`) runs Tarjan's algorithm over the same
  edges `Reachability` trusts, so a cycle of mutually-referencing-but-
  globally-dead declarations is reported as one finding instead of N.

`main.zig` is the CLI: it wires `--root`/`--dir`/`--library`/`--build-zig`
into `Project` + `Roots` + `Reachability`/`Scc`, and prints orphan files
then dead symbols (grouping cyclic components).

## Conventions

- Tests live beside their subject as `Foo_test.zig` (not inline `test {}`
  blocks in `Foo.zig` itself, except for trivial cases). Every new
  `*_test.zig` file must be added to the `test { ... }` block at the
  bottom of `src/root.zig` (`_ = @import("Foo_test.zig");`) or it
  will never run under `zig build test`.
- New cross-file resolution logic (anything extending what `Resolver`
  handles) typically needs wiring into the same three call sites that
  `InstanceType` and `FieldChain` already feed: `SymbolGraph` (same-file),
  `Resolver` (cross-file), and `Roots`' `.test`-root case (so test blocks
  benefit too).
- The project intentionally does no real type inference — only what's
  syntactically written down (explicit annotations, typed literals). If a
  fix would require inferring a type from usage rather than reading a
  declaration, it's likely out of scope; check `issues/` for whether it's
  already tracked as a known gap.
