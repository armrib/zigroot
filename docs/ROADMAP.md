# Roadmap

Phase 0-5 are done (see README.md). This tracks what's left to get from
"file-level orphan detection" to "declaration-level dead-code analysis
across a whole project".

## Phase 2 — Global symbol identity (done)

Added `src/project/SymbolId.zig`:

```zig
pub const SymbolId = struct {
    file: FileId,
    local: zlint.Semantic.Symbol.Id,
};
```

No remapping of ZLint's per-file symbol IDs — just pair them with the
owning `FileId`. Added `Project.symbol(id: SymbolId) *const zlint.Semantic.Symbol`.

## Phase 3 — Owner map (done)

For every AST node in a file, records which declaration (symbol) contains
it. Needed to invert ZLint's `Reference -> Symbol` links into
`Symbol -> Symbol` edges (Phase 4).

- `src/project/OwnerMap.zig`: `owner: []Symbol.Id.Optional` indexed by
  `Ast.Node.Index`. Built once per file, in `OwnerMap.build`, by indexing
  each symbol's `Symbol.decl` node and then, for every node, walking
  ZLint's already-computed `NodeLinks.parents` chain upward until it hits
  a node that's some symbol's `decl` — the nearest enclosing declaration.
- `File` holds its `OwnerMap` alongside `semantic`, built in `File.load`.

## Phase 4 — Same-file declaration graph (done)

Using `OwnerMap` + each `Reference.symbol` already resolved by ZLint,
build `SymbolId -> SymbolId` edges for references within one file.

- `src/project/SymbolGraph.zig`: adjacency keyed by `SymbolId`, same shape
  as `ImportGraph` (`edges: ArrayListUnmanaged(Edge)`,
  `adjacency: AutoHashMapUnmanaged(SymbolId, ArrayListUnmanaged(SymbolId))`).
  Built by iterating every symbol's already-resolved incoming references
  (`Symbol.Table.iterReferences`) and mapping each reference's node through
  `OwnerMap` to get the edge's source declaration.
- `File` builds and owns its `SymbolGraph` alongside `semantic` and
  `owner_map`.
- Test case: `fn a() void { b(); } fn b() void {}` produces edge `a -> b`.

## Phase 5 — Roots and reachability (done)

- `src/project/Roots.zig`: `RootKind = enum { executable_entry, @"test", @"export", public_api, configured }`.
  MVP: only `executable_entry` (each `--root` file's top-level `main`) and
  `.export` (symbols with the `s_export` flag, already tracked by ZLint) are
  populated; `Roots.build` walks `Project.roots` and every loaded file's
  symbol table.
- `src/project/Reachability.zig`: BFS over `SymbolGraph` from `Roots`,
  `O(V+E)`, via `Project.file(id).symbol_graph.outgoing`.
  `Reachability.deadSymbols` returns every declared symbol the BFS never
  reached.
- `main.zig` reports dead declarations after orphan-file detection.
- This is the first phase that produces genuine dead-code output:

  ```
  fn dead_a() void { dead_b(); }
  fn dead_b() void {}
  pub fn main() void {}
  ```

  → `dead_a`, `dead_b` unreachable, even though `dead_b` has a reference
  (the bug in ZLint's existing `unused-decls` this whole project works
  around). Same-file scoped, like `SymbolGraph`: a symbol only used across
  a `@import` boundary is still reported dead until Phase 6.

## Phase 6 — Cross-file imports (done)

Resolves `const storage = @import("storage.zig"); storage.start();` into a
`SymbolGraph` edge `main.main -> storage.start`.

- `src/project/Resolver.zig`: for every `ImportGraph` edge (Phase 1), finds
  the import binding's symbol via `OwnerMap.get(import_node)` (the same
  "nearest enclosing declaration" trick `OwnerMap` itself uses — the
  `@import(...)` call is a node inside the binding's own decl). For every
  reference to that binding used as a field-access base (`storage.start`,
  found by checking the reference node's parent via `node_links`), matches
  the field name against the target file's exports (`Symbol.exports` on the
  implicit file-root symbol, id `0`) and emits a `SymbolGraph` edge from the
  *referencing* declaration (via `OwnerMap` again) to the target export.
- `Reachability.build` now takes this cross-file graph alongside `Roots`
  and follows both when doing its BFS.
- Only resolves the `binding.member` shape. `Foo.bar()` static-member
  access and instance-method calls are still unresolved (Phase 7).

## Phase 7 — Container and static member resolution (done)

Added `src/project/FieldChain.zig`, shared by `SymbolGraph` (same-file) and
`Resolver` (cross-file):

- `fieldAccessName`: moved from `Resolver` — whether a node is the base of
  a `.field` access, and the field name if so.
- `findExport`: name lookup in a container's `Symbol.exports`.
- `resolve(ast, symbols, start, start_node)`: walks as many `.field` hops
  as resolve to an export, starting from `start` (declared in `symbols`,
  first referenced at `start_node` in `ast`). Stops at the first
  unresolvable hop — an instance value, an unmatched name, or a non-field
  use — returning however far it got.
- `SymbolGraph.build` now also calls `FieldChain.resolve` for every
  reference, adding an edge straight to the innermost resolved export
  alongside the existing direct edge to the referenced symbol, so
  `Foo.bar()` reaches both `Foo` and `bar`. Chains through arbitrarily many
  containers (`Outer.Inner.run()`).
- `Resolver.build` continues the chain after the `@import` hop: the first
  hop still matches the field name against the target file's exports (as
  in Phase 6), then `FieldChain.resolve` continues within the target
  file's `Semantic` for any further hops — so `storage.Inner.run()`
  resolves across the file boundary too.
- Only exports (static/container-level access) are walked. Instance-method
  calls (`server.run()` where `server` is a value of some type) still need
  real type inference and are left unresolved — Phase 9's
  `.dynamic_member_call`.

## Phase 8 — Tests, exports, library vs executable mode

- Synthetic root symbols for `test "..."` blocks (they have no declaration
  identity in ZLint's symbol table otherwise).
- `extern` declarations: never reported dead from local reachability alone.
- `PublicPolicy = enum { root, analyze }`: in library mode, `pub` is a root
  (external API); in executable mode, it isn't. CLI flag, default
  `analyze` (executable mode) since `--root` already implies an entry
  point.

## Phase 9 — Confidence levels for unresolved edges (done)

- `SymbolGraph.EdgeKind = enum { definite, possible, unknown }`, added to
  `Edge` and to `outgoing`'s return type (`Target { to, kind }`). Existing
  direct-reference and `FieldChain`-resolved edges are `.definite`.
- `src/project/DynamicField.zig`: resolves `@field(Foo, name)`, the
  flagship unresolved-access case `FieldChain` (a `.field_access` AST node)
  never sees since it's a builtin call instead. A comptime string-literal
  name resolves to one export at `.possible` confidence (a less-exercised
  code path than plain `Foo.bar`, so a notch less trusted). A runtime name
  can't name one target, so every export of the container becomes an
  `.unknown` edge — recorded rather than silently dropped. `SymbolGraph`
  wires this in the same reference-iteration loop that already drives
  `FieldChain`; cross-file `@field` (through `Resolver`'s `@import` hop),
  function pointers, and instance-method dynamic dispatch are still
  unresolved.
- `Reachability.build` only follows `.definite`/`.possible` edges in its
  BFS. Once that settles, a second pass over every `.unknown` edge whose
  source *is* reached marks its target `possiblyReachable` — not proven
  live, not silently called dead either. `deadSymbols` tags each result
  `{ id, possible }` instead of returning bare `SymbolId`s.
- CLI: default report only lists non-`possible` dead declarations;
  `--include-possible` widens it to include the uncertain ones too,
  annotated in the output.

## Phase 10 — SCC condensation (done)

- `src/project/Scc.zig`: Tarjan's algorithm over the same edge set
  `Reachability`'s BFS trusts (`.definite`/`.possible` from each file's
  `SymbolGraph` plus `Resolver`'s cross-file edges; `.unknown` excluded, for
  the same reason `Reachability` excludes it — a guessed edge shouldn't
  merge an uncertain target into a component of provably-dead code).
  `component_of` maps every symbol to its `ComponentId`; `members` lists a
  component's symbols; `isCyclic` reports whether the component is a real
  cycle rather than an isolated node — a plain Tarjan run can't tell those
  apart for a singleton component, so a second O(E) pass over every edge
  flags a component whose member has an edge (including a self-loop) back
  into the same component.
- `main.zig`: when a dead symbol's component `isCyclic`, its whole
  component is reported once (`cycle of N declaration(s), unreachable from
  any root:` followed by each member), instead of once per member.
  Non-cyclic singleton components still report individually, unchanged
  from Phase 9.

## Phase 11 — build.zig module graph integration (done)

- `src/project/BuildGraph.zig`: a syntactic scan over a `build.zig`'s AST
  (`std.zig.Ast`, not ZLint's `Semantic` — `build.zig` isn't project code
  under analysis) for the `const x = b.createModule(.{ .root_source_file =
  b.path("...") });` + `<module>.addImport("name", x);` shape. Not a real
  evaluation of the build script (that would mean running it); a
  `build.zig` with unrecognized shapes just yields a partial or empty
  graph rather than erroring. Modules that come from
  `b.dependency(...).module(...)` aren't backed by a local file and stay
  unresolved, same as before this phase.
- `Project.loadBuildGraph(path)`: parses `path`, storing the resulting
  name -> file mapping and the `build.zig`'s directory (mapped paths are
  relative to it). Must be called before `addRoot` for roots that use
  named-module imports it should resolve.
- `Project.loadRecursive`'s `.module` case now checks the build graph
  before falling back to `addUnresolved`: a resolved name is loaded and
  linked into `ImportGraph` exactly like a `.file` import.
- CLI: `--build-zig <build.zig>` flag, optional. Without it, named-module
  imports are unresolved as before (this phase is additive).

## Phase 12 — Cross-file `@field` resolution (done)

Phase 9's `DynamicField` only resolved `@field(Foo, name)` within one file;
a reference to an `@import` binding used as `@field`'s container argument
(`@field(storage, "start")`) fell through `Resolver`'s field-access-only
check and was silently dropped, unlike the same construct spelled
`storage.start()`.

- `DynamicField.resolve` now takes `ast` and `symbols` as separate
  `Semantic`s (mirroring `FieldChain.resolve`'s split): `ast` is where the
  `@field(...)` call and its node structure live (the referencing file),
  `symbols`/`container` is where the field name is matched against
  `Symbol.exports`. Same-file callers (`SymbolGraph`) pass one `Semantic`
  for both, `container` = the referenced symbol. `Resolver` passes the
  source file's `Semantic` as `ast` and the target file's `Semantic` with
  `FILE_ROOT_SYMBOL` as `symbols`/`container` — the same target-side
  handles `Resolver` already uses for the plain `storage.start()` hop.
- `Resolver.build`: a binding reference that isn't a field-access base now
  falls through to `DynamicField.resolve` instead of being skipped,
  producing a `.possible` edge (comptime-known name) or `.unknown` edges to
  every export (runtime name) into the target file — same confidence
  levels as the same-file case.
- Doesn't chain further after the `@field` hop (matching same-file
  `DynamicField`'s scope), and doesn't handle `@field` nested inside
  another resolved hop (e.g. through `FieldChain`-resolved containers).

## Phase 13 — Interleaved `.field` / `@field(...)` chaining (done)

Phase 12 crossed the `@import` boundary with `@field`, but `DynamicField`
still only resolved one hop: `@field(Foo, "Bar").baz()` stopped at `Bar`
(no further `.field` hop), and `@field(Outer.Inner, "run")` never resolved
at all (`Outer.Inner`'s field-access node was never offered to
`DynamicField` as an `@field` container argument).

- `FieldChain.resolveChain` replaces the old `FieldChain.resolve`: a single
  walk that tries a static `.field` hop first, falls back to a
  `DynamicField` `@field(...)` hop on the same node, and keeps going either
  way — so the two hop kinds interleave freely instead of `DynamicField`
  being a one-shot, dead-ending detour. Takes a starting `EdgeKind`-shaped
  `Kind` (`definite`/`possible`) so a caller that already crossed a
  less-certain hop (e.g. `Resolver`'s own `@field` boundary crossing) can
  seed the chain at `.possible`; a comptime-known `@field` hop downgrades to
  `.possible` for the rest of the chain, and a runtime-named `@field` hop
  still ends the chain (returned separately as `.unknown`, one edge per
  export of the container at that point) since it forks into multiple
  targets `resolveChain` can't keep chasing as one path.
- `SymbolGraph.build`, `Resolver.build`, and `Roots.build` (the `.test`-root
  case) all call `resolveChain` instead of separately calling the old
  `FieldChain.resolve` then `DynamicField.resolve` on the same un-chained
  starting node.
- `Resolver.build` seeds the chain at `.definite` when the `@import`
  boundary itself crossed via a plain `storage.field` hop, or `.possible`
  when it crossed via `@field(storage, "field")`, then keeps resolving
  further `.field`/`@field` hops within the target file either way.

## Later / not scheduled

- Per-target file sets (e.g. `linux.zig` vs `windows.zig` selected by
  `target.os.tag` inside `build.zig`) — `BuildGraph` resolves one
  `root_source_file` per module regardless of build options, so a
  conditionally-selected file always resolves to whichever branch's
  `b.path(...)` its scan finds. Genuinely evaluating `build.zig`'s control
  flow would need to actually run it.
