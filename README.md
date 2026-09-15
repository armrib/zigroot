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
- Option tables forwarded into a cross-file helper (Phase 33): `for
  (CODEGEN_FRONTENDS) |fe| { codegen.addCodegen(b, ..., fe); }`, where the
  helper roots a module at `b.path(opts.routes_src)` and names it. The
  inline form (`wire(b, .{ .routes_src = "..." })`) already resolved; the
  table form only needed to know which struct the loop capture stands for,
  and the table literal answers that for every iteration at once. Each
  element contributes its own candidate for the module name.
- Inline `@import("m").member` (Phase 34): written mid-expression rather
  than bound to a `const`, this has no binding whose references could be
  walked — the nearest enclosing declaration is what `OwnerMap` reports,
  and its references are references to *it*. The declaration containing the
  import is now edged straight to the member, and the chain continues from
  there (`@import("main").services_handler.collectServices`).
- Captures whose type lives in another file (Phase 35): `if (self.spoa)
  |sp| sp.onAccept(res)`, `for (self.conns) |c| c.close()` and `const ls =
  self.local;` all take their type from another declaration's type rather
  than one of their own. That walk was same-file only, so it stalled on the
  first hop whenever the method's file isn't the file declaring the struct
  — the split-implementation shape, where `HttpServer` is in one file and
  its io_uring completion arms are in another. Worse, it handed back the
  symbol it stalled on, and that wrong answer masked the cross-file retry.
  The walk now reports a stall as unresolved, and the resolver re-walks the
  same chain with the whole project behind it.
- Files the project reaches outside its own tree (Phase 36): a monorepo
  `sdks/` copy built into a backend *and* into six demos is judged here
  from the backend alone, so everything only the demos call reads as
  unreachable — and the only way to "fix" such a finding is to delete
  working code. A file outside the analyzed `build.zig`'s own directory
  now has its `pub` declarations treated as external API, the same way
  library mode treats the whole project's. Its non-`pub` declarations are
  still checked: nothing outside the file can reach those whatever else
  builds it.
- Test-support declarations (Phase 37): a `tmpRoot` or `StubAgent` helper
  sitting at the bottom of a production file is the same thing as a whole
  test-only *file* — which `Project.isTestOnly` already declines to call an
  orphan — just without a file of its own to be recognized by. Reachability
  now runs a second time with `test { ... }` blocks added as roots, and what
  that reaches but the production walk did not is reported as **test-only**:
  its own section, not a failure. `pub` declarations, orphan files and
  production code nothing but a test reaches are unaffected; only the
  reported class changes, and only for symbols a test actually reaches.
- Test-only *files* (Phase 38): a file reached only through test code used
  to be parsed just far enough to read its imports and then thrown away, so
  everything it referenced looked unreferenced — a whole `src/tests/`
  directory's worth of production code reported dead because its only
  callers sat in files the analysis had deliberately discarded. Those files
  are now loaded and tagged: they seed nothing as a production root, their
  own declarations are not findings, and what they reference is test-only by
  the Phase 37 rule. A reference written straight inside such a file's
  `test { ... }` block has no owning declaration to hang an edge on, so it
  is anchored at the file's own root symbol — which a production walk can
  never reach, since nothing outside test code imports the file at all.
- Members of an inline anonymous struct (Phase 39): `std.mem.sort(T, xs,
  {}, struct { fn lessThan(...) ... }.lessThan)`. The struct is never named,
  so there is no binding whose references could be walked, and ZLint never
  pushes an anonymous `struct { ... }` as a container of its own, so the
  `.lessThan` hop had nothing to resolve against — the one mention of the
  name in the whole project. The field name is now matched against the
  literal's own member list, edging the enclosing declaration to it.
- Types handed to code that can't be read (Phase 40): `pwriteFull(FdWriter{
  .fd = fd }, ...)` against a `writer: anytype` parameter, and `std.HashMap(K,
  V, KeyContext, ...)` against a generic living in an external module. Both
  reach into a container by a name that appears nowhere visible — the only
  `write` caller is inside an `anytype` body, the only `hash` caller is
  inside `std`. Which members get used isn't knowable, so every export of
  the argument's type is edged at `.unknown`, landing those members in the
  **possibly dead** section rather than the failing one. A callee that
  merely didn't resolve is deliberately *not* treated this way: most of
  those are ordinary method calls, and assuming the worst of them would
  edge half the project.
- What a `test`/`comptime` block reaches across a file boundary (Phase 41):
  a reference written straight inside one of those blocks has no owning
  declaration, so no graph edge ever carries it and `Roots` has to seed what
  it reaches directly. That seeding was same-file only, and stopped at the
  first hop `FieldChain` can't finish alone — `var pool = StringPool.init();
  pool.unmintFrom(...)`, where `pool`'s type is only known from a call
  return in another file. The chain is now walked with the whole project
  behind it, which pulled a further 29 formic findings out of *dead* and
  into *test-only*.
- `&container.array[i]` across a file boundary (Phase 42): the same stall
  Phase 35 fixed for captures, in the one shape it left out. The one-hop
  `crossFileRoot` shortcut resolves a field off whichever symbol the
  same-file walk stalled on — for `const c = &state.conns[i];` that is
  `state`, so it answered `State` and dropped the field and index hops that
  were the whole point. The full chain walk now runs first, and an
  address-of chain is marked as landing on the element type itself rather
  than on a declaration whose type still has to be read.

- An anonymous struct as a return type (Phase 43): `pool.acquire()` returning
  `?struct { id: u16, worker: *Worker }` has no symbol to hand back as the
  variable's type, so every hop off it went unresolved — taking the whole
  `Worker` method set with it. The hop's field name is matched against the
  return type's own member list, and the walk resumes from that member's
  declared type.

- A call through a function-pointer field (Phases 44-45): `log_lookup_fn: ?*const
  fn (ctx: ?*anyopaque, id: u8) ?*Log`, invoked as `if (self.log_lookup_fn) |f|
  { if (f(ctx, id)) |log| ... }`. Two gaps met here. The callee is a field, not
  a declaration with a body, so there was no `fn` symbol to read a return type
  off — it is read from the field's own annotation instead, walking back to that
  field the way Phase 35 walks back to any capture's source. And an `if`
  payload whose condition is a *call* rather than a chain had no type at all —
  the callee's return type is now resolved for that shape too.

- What a possibly-reached symbol uses (Phase 46): only the direct target of an
  `.unknown` edge used to be marked possibly reached, so anything that target
  alone used came out dead-for-certain. `Log.FdWriter.write` is named only
  through an `anytype` parameter; the error set and errno classifier nothing
  else calls were reported as real findings. Possible reachability now
  propagates, following every edge kind — past that first guess there is
  nothing left to hedge.

- An ambiguous module name (Phase 47): two `build.zig` files in one project can
  register the same module name for different files — formic's `apps/iamd` and
  `apps/clusterd` both call theirs "scheduler". Every candidate is edged from
  the one `@import` node, and taking the first landed in the wrong file, so
  every hop off it failed and the right file's whole export set read as
  unreachable. The field being hopped disambiguates: only one candidate
  declares it.

- A variable initialized from an `if` expression (Phase 48): `const pool = if
  (tag.pool_id == SA_POOL_ID) pools.sa else pools.login;` has its type in the
  branches and nowhere else. Both branches have to agree for the program to
  compile, so the first that resolves is the answer.

- A field declared after an inline `enum` field (Phase 49, in the vendored
  semantic layer): `state: enum { free, reading }` marked the *enclosing*
  struct `s_enum`, after which every later field's type expression went
  unvisited — so `write_buf: [RESPONSE_MAX]u8` recorded no reference at all
  and `RESPONSE_MAX` read as dead. The flags now only land on a container
  that has a symbol of its own.

- An optional payload captured off a call-typed variable (Phase 50): `var gz =
  compressGzip(...) catch null; if (gz) |*g| g.deinit();`. The chain from `gz`
  has no hops to walk, so it landed back on `gz` and a guard meant to stop
  non-terminating recursion discarded the answer. Landing back on the chain's
  own start is now read as "this symbol's own type is the answer"; only landing
  back on the symbol being resolved still bails.

- A `for` over a sliced expression (Phase 51): `for (snap.disks[0..snap
  .disk_count]) |d|`. The bounds change how much is iterated, never the element
  type, so the slice wrapper is stripped before the chain base is read.

- A hop off a generic container from an unanalyzed module (Phase 52):
  `redirect_uri_pending: std.ArrayList(RedirectUriRequest)` iterated as `for
  (self.redirect_uri_pending.items) |*existing|`. There is no `items` to find
  and no return type to read, but the element type is written right there in
  the instantiation. Only an `items` hop is matched — that is the one field
  name whose meaning is fixed across std's list types — and the argument is
  followed through the local alias it is usually spelled with.

- A hop off an anonymous type written inline (Phase 53): `body: union(enum) {
  memory: struct { ..., pub fn slice(...) } }`, reached as
  `req.body.memory.slice()`. There is no symbol standing for that type, so the
  hop is matched against its member list directly — the same trick Phase 43
  uses for an anonymous return type.

- A multi-hop chain off an `anytype` parameter (Phase 54): `clearOnRing(server:
  anytype)` calling `server.file_ops.unlink(ring, path)`. The whole-export-set
  guess reached `file_ops` and stopped, leaving `FileOps.unlink` dead. When the
  callee is a project function its body says exactly which chains it walks, so
  those are re-walked against the type the call site actually passed — precise,
  and past the first hop. The guess stays for a callee this project never
  analyzes (`std.HashMap(K, V, Ctx, ...)`), where nothing can say.

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
