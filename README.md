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
- `Roots`: automatic reachability roots — each root file's top-level
  `main` (`executable_entry`), every `export`ed symbol (`.export`), every
  symbol a container-level `comptime { ... }` block references
  (`.comptime_block`), and, under `PublicPolicy.root` (library mode,
  auto-detected when `build.zig` defines a library and no executable),
  every `pub` symbol
  (`.public_api`) (`src/Roots.zig`).
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
- `BuildGraph`: a syntactic scan of the current directory's `build.zig`
  local module graph (`b.createModule(...)` + `.addImport("name", ...)`
  bindings), so named-module imports like `@import("storage")` resolve to
  their file instead of staying unresolved (`src/BuildGraph.zig`). Also
  extracts every `addExecutable`/`addLibrary`/`addTest` root module as a
  project root. Dependency modules (`b.dependency(...)`) stay unresolved,
  since they aren't backed by a local file. Bindings are name-keyed and
  file-wide, so a `build.zig` split into stratified helpers (`fn
  wireAuth(b, fnd: Foundation)` importing `fnd.storage`) resolves through
  the field name alone when the caller's struct binding hasn't been seen yet.
  A root module given as a field access (`b.addExecutable(.{ .root_module =
  mods.main })`, where `mods` came from a local helper returning a struct of
  modules) resolves the same way an `addImport`'s module argument does —
  that's the shape a per-app `apps/<name>/build.zig` called as
  `app_build.wire(b, ...)` from the aggregating `build.zig` typically uses,
  and missing it costs a whole binary's reachability, not one declaration's.
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
  own references the same way. `InstanceType` also reads a function
  *parameter*'s declared type the same way, so `self`-receiver methods
  (`fn visit(self: *Foo) void { self.run(); }`) resolve `self.run()` the
  same way a locally-declared `var s: Foo` does.
- Value aliases and decl literals: `const Project = zigroot.Project;`
  (itself a re-export of `@import("Project.zig")` elsewhere), `const FileId
  = @import("FileId.zig").FileId;`, `const Mixin = util.Bitflags(Flags);`
  are followed to whatever they name, across as many files as it takes,
  wherever a chain lands on one — as a hop base, a declared type, or a
  call's return type. `var p: Project = .init(gpa);` / `return .empty;` /
  `field: T = .none` resolve the literal against the type written on the
  enclosing declaration (`src/DeclLiteral.zig`). `const semantic =
  &project.file(id).semantic;` takes the declared type of what the chain
  lands on. Intermediate hops (`Inner` in `Outer.Inner.run()`) count as
  used, not just the chain's end.
- Test code doesn't count as use. A declaration only a `test { ... }`
  block references is dead; an `@import` written inside a test block is
  not followed, and the target (plus whatever only it imports, and every
  `b.addTest` root module) is a *test-only file* — listed, never analyzed,
  never an orphan. A plain alias only tests reference (`const t =
  std.testing;`) is scaffolding, not a finding. Container-level `comptime {
  _ = x; }` blocks do seed roots.
- Only declarations are findings: a `fn`/`const`/`var` declared directly
  in a container. Parameters, locals, captures and container fields fold
  into a dead parent's `(+N nested)` count instead.
- `build.zig.zon` (`src/ZonFile.zig`): dependency names are external
  modules (never dead, never an "unresolved import"), and `.path`
  dependencies are excluded from orphan discovery. `std`/`builtin`/`root`
  and any `addImport` name `build.zig` binds to a `b.dependency(...)`
  module are external too; only genuinely unaccounted-for imports are
  printed as unresolved.
- Parse errors are surfaced (`path:line:col: message`) and exit 2: a file
  with syntax errors has a partial symbol table, so its findings can't be
  trusted.

- `&self.slice[i]` (Phase 31): an un-annotated variable initialized from an
  `address_of` chain whose indexed hop lands on an element type in *another*
  file used to give up, because `InstanceType` has no `Project` to follow the
  `@import` with. It now hands the slice field it stuck on to `crossFileRoot`,
  so `Resolver` finishes the hop — `var p = &self.parsers[id]; p.feed();`
  reaches `feed` the same way an explicit `var p: *http.Parser` annotation did.
- `.?` unwraps (Phase 31) are stepped over inside a chain rather than ending
  it: `self.spoa.?.onRecv()` resolves against the optional's payload type, the
  same as the `if (self.spoa) |s| s.onRecv()` capture already did.
- `build.zig` helpers that take the path (Phase 32): a test registered as
  `addModuleTest(b, opts, "domains/agent/supervision_test.zig", ...)` — a
  local helper whose body does `b.createModule(.{ .root_source_file =
  b.path(path) })` and then `b.addTest(.{ .root_module = m })` — is now a
  root. The path is a literal at the call site, so only the hop from
  argument position to parameter name is needed, no evaluation.
- `build.zig` tables walked by a `for` loop (Phase 32): the same shape one
  level out, `for (platform_test_files) |pt| { ... b.path(pt.path) ... }`,
  including tuple tables read by index (`b.path(tc[1])`). Every path the
  table literal names becomes a root of whatever the loop body builds —
  `addTest` or `addExecutable`/`addLibrary`.
- Bindings are collected in their own pass (Phase 32) before anything that
  reads one, so a stratified `build.zig` that declares `wireExe` — which
  says `addImport("mph", shared.mph)` — above the `wire()` that binds
  `const shared = wireShared(...)` no longer drops the module. Bindings are
  still rebuilt in source order during the main pass, so sibling blocks
  reusing one variable name each keep their own module.

Not handled, by design: real type inference for instance-method calls
(`inflight.cont.call()` where `inflight` comes from `map.fetchRemove(...)`),
generic instantiation tracking beyond a `type`-returning function's own
`return struct { ... }`, `@embedFile`/`@cImport`, and `build.zig` shapes
that need the script actually evaluated (a custom module-registry helper
struct, say) rather than scanned.

`BuildGraph` doesn't evaluate `build.zig`'s control flow (that would mean
actually running it), so it can't tell which branch of a per-target file
set (e.g. `linux.zig` vs `windows.zig` picked by `target.os.tag`) actually
runs. Rather than guess, it keeps every `addImport`-bound candidate for a
given import name and treats them all as reachable — over-approximating
reachability instead of risking a false orphan/dead report for the branch
not taken.

## Build

Requires Zig 0.15.x. No dependencies to fetch: the semantic layer is
vendored under `src/semantic/` (see "Credits" below).

```sh
zig build test
zig build
```

## Run

```sh
cd path/to/some/project   # a directory with a build.zig
zigroot
```

zigroot takes no arguments. Run it from a directory containing a
`build.zig`; it loads that `build.zig`'s `addExecutable`/`addLibrary`/
`addModule` root modules as project roots (and `addTest` roots only to
classify test-only files), resolves the named-module `@import(...)`s it
wires up via `b.createModule(...)` + `.addImport(...)`, reads
`build.zig.zon` for external dependencies, and scans `.` for orphan `.zig`
files. A `build.zig` that defines a library (`addLibrary` or `addModule`)
and no executable is analyzed in library mode (every `pub` symbol counts
as reachable API); otherwise `pub` alone doesn't make a symbol a root.

Output, in order: parse errors, external modules, unresolved imports,
test-only files, orphan files, dead declarations
(`path:line:col: kind name`, sorted by file and line, a dead cycle
collapsed into one line), and possibly-dead declarations (only reached
through a runtime-named `@field(...)`). Paths are relative to the
`build.zig` directory.

Exit codes: 0 clean, 1 if any orphan file or dead declaration was found,
2 if the project couldn't be loaded or some file has parse errors.

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
  Roots.zig                   automatic reachability roots (main, export, comptime, pub policy)
  Reachability.zig            BFS over SymbolGraph + Resolver edges from Roots
  Resolver.zig                cross-file Symbol -> Symbol edges via @import
  FieldChain.zig              Foo.bar() / Outer.Inner.run() export-chain resolution
  DynamicField.zig            @field(Foo, name) resolution (comptime + runtime name)
  InstanceType.zig            locally-typed variable -> declared-type symbol resolution
  DeclLiteral.zig             .init(...) / return .empty -> expected-type member resolution
  Scc.zig                     Tarjan SCC over the declaration graph
  Report.zig                  findings with path:line:col, cycles collapsed
  BuildGraph.zig              build.zig module-name -> file resolution
  ZonFile.zig                 build.zig.zon dependency names and path dependencies
  self_test.zig               integration test: analyzes this repo, pins the expected findings
  main.zig                    CLI
  semantic/                   per-file semantic analysis (copied from ZLint, see below)
```

## Credits

The per-file semantic analysis under `src/semantic/` is copied from
[ZLint](https://github.com/DonIsaac/zlint) by Don Isaac (MIT), commit
[`8cbbb1c`](https://github.com/DonIsaac/zlint/commit/8cbbb1c9c48ebc091d9b230bb98355d53cc251ad),
and modified. See `src/semantic/UPSTREAM.md` for the list of changes.
