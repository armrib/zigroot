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

The README's "Status" section is the living design log — read it before
changing `src/*.zig` to understand what's implemented and what's an
intentional gap. Known gaps with a repro go in `issues/NN-*.md` (the
directory doesn't exist while there are none); each is a single gap with
a measured/example repro and a sketch of the fix. **When a fix lands that
closes an issue, delete its `issues/NN-*.md` file in the same change** —
don't leave closed tickets sitting around, and don't just mark them done
in place. The same goes for any `docs/TODO*.md` work list: delete what's
done.

Two semantics to keep in mind, both deliberate: test code doesn't count
as use (a declaration only a `test` block reaches is dead; a file only a
test reaches is test-only, not analyzed), and only declarations are
findings (parameters, locals, fields fold into their dead parent).

## Commands

```sh
zig build test      # run the whole test suite
zig build            # build zig-out/bin/zigroot
zig build run         # build+run against this repo's own build.zig
```

Requires Zig 0.15.x. There are no package dependencies: the per-file
semantic layer is a modified copy of ZLint's, vendored under
`src/semantic/` (MIT; provenance and the list of local modifications live
in `src/semantic/UPSTREAM.md` — update that list whenever a file in that
directory is edited). ZLint's `main` branch moved to Zig 0.16's
`Io`-threaded filesystem API after the copied commit, so pulling newer
upstream changes into `src/semantic/` means porting them.

There's no dedicated single-test filter wired up in `build.zig`; run the
full `zig build test` (it's fast — the corpus is this repo's own small
`src/` tree plus synthetic fixtures inline in each `*_test.zig`).

zigroot takes no arguments: run it from a directory containing a
`build.zig` and it loads that `build.zig`'s `addExecutable`/`addLibrary`/
`addTest` root modules as project roots automatically. Run zigroot on
itself:
```sh
zig-out/bin/zigroot
```
Or `cd` into a checkout of ZLint (`git clone https://github.com/DonIsaac/zlint`)
for a bigger real-world corpus, since it has its own `build.zig`.

Exits 1 if any orphan files or dead declarations are found, 2 on a load
or parse error.

`src/self_test.zig` runs the analysis on this repository itself under
`zig build test` and pins the expected findings: a change that makes a
project-layer declaration newly dead (or newly reached) fails it, and any
new finding under `src/semantic/` is tolerated (that tree is copied
upstream API). Update its expected list deliberately when the CLI's own
surface changes.

## Architecture

Everything is layered on ZLint's per-file `Semantic`:

- `File` (`src/File.zig`) parses one file and owns its ZLint
  `Semantic`, plus a derived `OwnerMap` and `SymbolGraph` built alongside it.
- `Project` (`src/Project.zig`) loads root files, follows
  `@import("*.zig")` transitively via `ImportGraph`, and holds all `File`s.
  An `@import` inside a `test` block is not followed: its target and
  everything only it imports (and every `b.addTest` root module) is a
  test-only file — recorded, never analyzed, never an orphan. Any other
  `.zig` file under the scanned directory that no root's import graph
  reaches is an orphan file. `ZonFile` (`src/ZonFile.zig`) reads
  `build.zig.zon` so dependency names classify as external imports and
  path dependencies stay out of orphan discovery.
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
  do. `DeclLiteral.zig` finds `.init(...)`/`.empty` literals and the type
  node they resolve against. `Resolver` also follows value aliases
  (`const Project = zigroot.Project;`, `@import(...).X`, a call to a
  `type`-returning function) wherever a chain lands on one
  (`FieldChain`'s `stuck_alias`), resolves any written-down declared type
  that didn't resolve same-file, and edges every intermediate hop of a
  chain. None of this is real type inference — it's reading what's
  already spelled out in the AST.
- `BuildGraph` (`src/BuildGraph.zig`) is a syntactic scan of the
  current directory's `build.zig` local module graph (`b.createModule` +
  `.addImport("name", ...)`), so named-module imports like
  `@import("storage")` resolve to a file instead of staying unresolved.
  Also extracts every `addExecutable`/`addLibrary`/`addModule` root
  module, loaded as an analysis root, and every `addTest` root, loaded
  only to classify test-only files; an `addImport` name bound to a
  `b.dependency(...)` module is recorded as external.
- `Roots` (`src/Roots.zig`) computes automatic reachability roots:
  each root file's top-level `main`, every `export`ed symbol, every
  symbol a container-level `comptime { ... }` block references, and —
  under `PublicPolicy.root`, chosen automatically when `build.zig`
  defines a library (`addLibrary`/`addModule`) and no executable — every
  `pub` symbol. Test blocks seed nothing.
- `Reachability` (`src/Reachability.zig`) is a BFS over
  `SymbolGraph` + `Resolver`'s cross-file edges starting from `Roots`;
  `deadSymbols` is everything the BFS never reaches. `extern` declarations
  are excluded since their implementation lives outside the project.
- `Scc` (`src/Scc.zig`) runs Tarjan's algorithm over the same
  edges `Reachability` trusts, so a cycle of mutually-referencing-but-
  globally-dead declarations is reported as one finding instead of N.
- `Report` (`src/Report.zig`) turns dead symbols + `Scc` into sorted
  `path:line:col: kind name` findings with cycles collapsed, shared by
  the CLI and `self_test.zig`.

`main.zig` is the CLI: it takes no arguments, loading the current
directory's `build.zig` into `Project` + `Roots` (inferring library vs.
executable policy from whether `build.zig` defines a library and no
executable) + `Reachability`/`Scc`/`Report`, and prints parse errors,
external modules, unresolved imports, test-only files, orphan files, dead
declarations and possibly-dead declarations.

## Conventions

- Tests live beside their subject as `Foo_test.zig` (not inline `test {}`
  blocks in `Foo.zig` itself, except for trivial cases). Every new
  `*_test.zig` file must be added to the `test { ... }` block at the
  bottom of `src/root.zig` (`_ = @import("Foo_test.zig");`) or it
  will never run under `zig build test`.
- New cross-file resolution logic (anything extending what `Resolver`
  handles) typically needs wiring into the two call sites that
  `InstanceType` and `FieldChain` already feed: `SymbolGraph` (same-file)
  and `Resolver` (cross-file). A chain `FieldChain` can't finish
  same-file comes back as `stuck`/`stuck_call`/`stuck_alias` for
  `Resolver.addChain` to resume — prefer extending that over adding a
  parallel walk.
- The project intentionally does no real type inference — only what's
  syntactically written down (explicit annotations, typed literals,
  aliases, return types). If a fix would require inferring a type from
  usage rather than reading a declaration, it's likely out of scope;
  check `issues/` (if present) for whether it's already tracked as a
  known gap.
- After changing resolution, run `zig build test` (which includes the
  self-run) and eyeball `zig build run`'s output: every finding under
  `src/semantic/` should be upstream API nothing here calls.
