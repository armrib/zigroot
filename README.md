# zigroot

A whole-project reachability analyzer built on top of [ZLint](https://github.com/DonIsaac/zlint)'s
per-file `Semantic` layer. ZLint's semantic analysis is deliberately
single-file; `zigroot` adds the project layer above it: file discovery,
`@import("*.zig")` resolution, and (eventually) cross-file declaration
reachability so mutually-referencing-but-globally-dead code can be found
across a whole codebase, not just within one file.

Status: Phase 0-16. Implemented so far:

- `Project`: loads root files, follows `@import("*.zig")` transitively,
  builds a file-level import graph (`src/Project.zig`,
  `src/ImportGraph.zig`).
- Orphan-file detection: any `.zig` file under a scanned directory that no
  configured root reaches via `@import`.
- Named-module imports (`@import("std")`, `@import("some_dep")`) are
  recorded as unresolved rather than treated as errors — resolving those
  needs `build.zig` module information, which is future work.
- `SymbolId`: pairs one of ZLint's per-file `Symbol.Id`s with the owning
  `FileId`, giving a project-wide symbol identity (`src/SymbolId.zig`).
- `OwnerMap`: for every AST node in a file, the declaration (symbol) whose
  body contains it, derived from ZLint's per-node parent links
  (`src/OwnerMap.zig`). `File` builds one alongside its `semantic`.
- `SymbolGraph`: same-file `Symbol -> Symbol` reference edges, built by
  mapping every symbol's already-resolved incoming references through
  `OwnerMap` (`src/SymbolGraph.zig`). `File` builds one alongside
  its `semantic` and `OwnerMap`.
- `Roots`: automatic reachability roots — each `--root` file's `main`
  (`executable_entry`), every `export`ed symbol (`.export`), every symbol
  referenced from a `test { ... }` block (`.test`, since ZLint gives `test`
  blocks no symbol identity of their own to make a root out of directly),
  and, under `PublicPolicy.root` (library mode, `--library`), every `pub`
  symbol (`.public_api`) (`src/Roots.zig`).
- `extern` declarations are excluded from `deadSymbols` — their
  implementation lives outside the project, so local reachability can't
  justify calling them dead (`src/Reachability.zig`).
- `Reachability`: BFS over `SymbolGraph` from `Roots`, plus `Resolver`'s
  cross-file edges; `deadSymbols` lists every declared symbol the BFS never
  reaches (`src/Reachability.zig`). The CLI reports these after
  orphan-file detection.
- `Resolver`: resolves `const storage = @import("storage.zig");
  storage.start();` into a cross-file `SymbolGraph` edge, by matching a
  member-access reference on an import binding against the target file's
  exported symbols (`src/Resolver.zig`).
- `FieldChain`: resolves `Foo.bar()` and `Outer.Inner.run()` static-member
  chains through ZLint's `Symbol.exports`, both same-file (`SymbolGraph`)
  and across an `@import` boundary (`Resolver`) — no type inference, just
  container graph traversal (`src/FieldChain.zig`).

- `Scc`: Tarjan's algorithm over the same edges `Reachability` trusts, so a
  cycle of mutually-referencing-but-globally-dead declarations is reported
  as one finding instead of N (`src/Scc.zig`). The CLI groups a
  dead symbol's whole cyclic component into one `cycle of N
  declaration(s)...` report.
- `BuildGraph`: a syntactic scan of a `build.zig`'s local module graph
  (`b.createModule(...)` + `.addImport("name", ...)` bindings), so
  named-module imports like `@import("storage")` resolve to their file
  instead of staying unresolved (`src/BuildGraph.zig`). Enabled
  with `--build-zig <path>`; dependency modules (`b.dependency(...)`) stay
  unresolved, since they aren't backed by a local file.
- `DynamicField` now also resolves `@field(...)` across an `@import`
  boundary (`@field(storage, "start")`), via the same target-file
  export-matching `Resolver` uses for `storage.start()`
  (`src/DynamicField.zig`, `src/Resolver.zig`).
- `FieldChain.resolveChain` interleaves static `.field` hops and
  `@field(...)` hops in one walk, so `@field(Foo, "Bar").baz()` and
  `@field(Outer.Inner, "run")` both resolve as far as they can — instead of
  `@field` being a one-hop dead end — both same-file (`SymbolGraph`) and
  across an `@import` boundary (`Resolver`) (`src/FieldChain.zig`).

- `InstanceType`: resolves a variable's syntactically-declared type (an
  explicit type annotation or a typed struct-literal initializer) to that
  type's symbol, so `var s: Foo = ...; s.run();` reaches `Foo`'s `run` the
  same way `Foo.run()` does — not real type inference, just reading what's
  already written down (`src/InstanceType.zig`, wired into
  `SymbolGraph`). `Resolver` extends this across an `@import` boundary too:
  `var s: storage.Widget = ...; s.run();` resolves `storage.Widget` into the
  target file's exports the same way `storage.foo()` does, then chains `s`'s
  own references the same way. `Roots`' `.test`-root case resolves instance
  types too, both same-file and cross-file, so an instance-method call in a
  `test { ... }` block seeds reachability from the method the same way a
  static `Foo.run()` call in a test already did. `InstanceType` also reads a
  function *parameter*'s declared type the same way, so `self`-receiver
  methods (`fn visit(self: *Foo) void { self.run(); }`) resolve `self.run()`
  the same way a locally-declared `var s: Foo` does — same-file and across
  an `@import` boundary, both through `SymbolGraph`/`Resolver` and `Roots`'
  `.test`-root case.

Not yet implemented: an instance type named through a same-file chain
*before* crossing an `@import` boundary (`var s: mod.storage.Widget =
...`), a nested `const Self = @This();` alias (only the file-top-level case
resolves), per-target file sets in `build.zig` (e.g. `linux.zig` vs
`windows.zig` chosen by target), and a few other gaps found by running
against a real codebase. See `issues/` for the full list.

## Build

Requires Zig 0.15.x (ZLint is a package dependency pinned to a pre-0.16
commit; see "Zig version" below).

```sh
zig build --fetch   # first time only, fetches ZLint (and its own deps)
zig build test
zig build
```

## Run

```sh
zig-out/bin/zigroot --root src/root.zig --root src/main.zig --dir src
```

- `--root <file.zig>`: a project entry point, followed transitively through
  `@import("*.zig")`. Repeatable.
- `--dir <path>`: directory to scan for orphan `.zig` files (default `.`).
- `--library`: treat every `pub` symbol as reachable library API (default:
  executable mode, where `pub` alone doesn't make a symbol a root).
- `--build-zig <build.zig>`: resolve named-module `@import(...)`s that
  `build.zig` wires up locally via `b.createModule(...)` +
  `.addImport(...)`, instead of leaving them unresolved.

Exits non-zero if any orphan files are found.

## Layout

```
src/
  root.zig                    library entry point, re-exports Project
  Project.zig                 file graph + orphan detection
  FileId.zig
  File.zig                    one parsed+analyzed file (owns zlint.Semantic + OwnerMap)
  ImportGraph.zig             file-level @import edges
  SymbolId.zig                project-wide symbol identity
  OwnerMap.zig                node -> containing-declaration map
  SymbolGraph.zig             same-file Symbol -> Symbol reference edges
  Roots.zig                   automatic reachability roots (main, export, test, pub policy)
  Reachability.zig            BFS over SymbolGraph + Resolver edges from Roots
  Resolver.zig                cross-file Symbol -> Symbol edges via @import
  FieldChain.zig              Foo.bar() / Outer.Inner.run() export-chain resolution
  DynamicField.zig            @field(Foo, name) resolution (comptime + runtime name)
  InstanceType.zig            locally-typed variable -> declared-type symbol resolution
  Scc.zig                     Tarjan SCC over the declaration graph
  BuildGraph.zig              build.zig module-name -> file resolution
  main.zig                    CLI
```

ZLint itself is a `zig fetch`-managed package dependency (see
`build.zig.zon`), not vendored in this tree.

## Zig version

ZLint's `main` branch moved to Zig 0.16's `Io`-threaded filesystem API
(`Dir.readFile(dir, io, ...)`, etc.). To keep this scaffold on the more
stable classic `std.fs` API, `build.zig.zon` pins the `zlint` dependency to
[`8cbbb1c`](https://github.com/DonIsaac/zlint/commit/8cbbb1c9c48ebc091d9b230bb98355d53cc251ad),
the last commit before that migration (targets Zig 0.15.x). Re-evaluate
this pin before adding new ZLint-derived code.
