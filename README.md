# zigroot

A whole-project reachability analyzer built on top of [ZLint](https://github.com/DonIsaac/zlint)'s
per-file `Semantic` layer. ZLint's semantic analysis is deliberately
single-file; `zigroot` adds the project layer above it: file discovery,
`@import("*.zig")` resolution, and (eventually) cross-file declaration
reachability so mutually-referencing-but-globally-dead code can be found
across a whole codebase, not just within one file.

Status: Phase 0-1 MVP. Implemented so far:

- `Project`: loads root files, follows `@import("*.zig")` transitively,
  builds a file-level import graph (`src/Project.zig`,
  `src/project/ImportGraph.zig`).
- Orphan-file detection: any `.zig` file under a scanned directory that no
  configured root reaches via `@import`.
- Named-module imports (`@import("std")`, `@import("some_dep")`) are
  recorded as unresolved rather than treated as errors — resolving those
  needs `build.zig` module information, which is future work.

Not yet implemented: declaration-level reachability, cross-file member
resolution (`storage.start()`), roots beyond explicit `--root` (tests,
exports, `pub` policy), SCC reporting. See the design discussion this was
scaffolded from for the full phase plan.

## Build

Requires Zig 0.15.x (ZLint is vendored at a pre-0.16 commit; see
"Zig version" below).

```sh
zig build --fetch   # first time only, fetches ZLint's own deps
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

Exits non-zero if any orphan files are found.

## Layout

```
src/
  root.zig                    library entry point, re-exports Project
  Project.zig                 file graph + orphan detection
  project/
    FileId.zig
    File.zig                  one parsed+analyzed file (owns zlint.Semantic)
    ImportGraph.zig           file-level @import edges
  main.zig                    CLI
vendor/zlint/                 git submodule, pinned to a pre-0.16 commit
```

## Zig version

ZLint's `main` branch moved to Zig 0.16's `Io`-threaded filesystem API
(`Dir.readFile(dir, io, ...)`, etc.). To keep this scaffold on the more
stable classic `std.fs` API, `vendor/zlint` is pinned to
[`8cbbb1c`](https://github.com/DonIsaac/zlint/commit/8cbbb1c9c48ebc091d9b230bb98355d53cc251ad),
the last commit before that migration (targets Zig 0.15.x). Re-evaluate
this pin before adding new ZLint-derived code.
