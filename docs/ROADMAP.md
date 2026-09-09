# Roadmap

Phase 0-3 are done (see README.md). This tracks what's left to get from
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

## Phase 4 — Same-file declaration graph

Using `OwnerMap` + each `Reference.symbol` already resolved by ZLint,
build `SymbolId -> SymbolId` edges for references within one file.

- `src/project/SymbolGraph.zig`: adjacency keyed by `SymbolId`, same shape
  as `ImportGraph` (`edges: ArrayListUnmanaged(Edge)`,
  `adjacency: AutoHashMapUnmanaged(SymbolId, ArrayListUnmanaged(SymbolId))`).
- Test case: `fn a() void { b(); } fn b() void {}` produces edge `a -> b`.

## Phase 5 — Roots and reachability

- `src/project/Roots.zig`: `RootKind = enum { executable_entry, test, export, public_api, configured }`.
  MVP: only `executable_entry` (from `--root`'s `main`) and `.export` (symbols
  with `s_export` flag, already tracked by ZLint).
- `src/project/Reachability.zig`: BFS/DFS over `SymbolGraph` from roots,
  `O(V+E)`.
- This is the first phase that produces genuine dead-code output:

  ```
  fn dead_a() void { dead_b(); }
  fn dead_b() void {}
  pub fn main() void {}
  ```

  → `dead_a`, `dead_b` unreachable, even though `dead_b` has a reference
  (the bug in ZLint's existing `unused-decls` this whole project works
  around).

## Phase 6 — Cross-file imports

Resolve `const storage = @import("storage.zig"); storage.start();` into a
`SymbolGraph` edge `main.main -> storage.start`, using the file-level edges
`ImportGraph` (Phase 1) already has plus the import symbol's usages.

- `src/project/Resolver.zig`: given an import binding
  (local symbol -> target `FileId`) and a member-access reference on that
  symbol, resolve to the target file's exported symbol of the same name.

## Phase 7 — Container and static member resolution

Extend the resolver to `Foo.bar()` and `Outer.Inner.run()` using ZLint's
existing `Symbol.exports` / `Symbol.members` — no type inference needed,
just graph traversal over container relationships ZLint already computed.

Do not attempt instance-method resolution (`server.run()` where `server`
is a value of some type) — that needs real type inference. Conservatively
mark such call sites `.dynamic_member_call` (Phase 9) instead of guessing.

## Phase 8 — Tests, exports, library vs executable mode

- Synthetic root symbols for `test "..."` blocks (they have no declaration
  identity in ZLint's symbol table otherwise).
- `extern` declarations: never reported dead from local reachability alone.
- `PublicPolicy = enum { root, analyze }`: in library mode, `pub` is a root
  (external API); in executable mode, it isn't. CLI flag, default
  `analyze` (executable mode) since `--root` already implies an entry
  point.

## Phase 9 — Confidence levels for unresolved edges

`EdgeKind = enum { definite, possible, unknown }`. Anything that can't be
statically resolved (`@field(Foo, name)`, function pointers, dynamic
dispatch) produces an `unknown` edge rather than being silently dropped or
treated as reachable/dead. Default CLI report only lists `definite` dead
declarations; `--include-possible` widens it.

## Later / not scheduled

- SCC condensation (Tarjan) for reporting dead reference cycles as one
  finding instead of N.
- Real `build.zig` module graph integration instead of `--root` flags, so
  `@import("some_dep")` and per-target file sets (e.g. `linux.zig` vs
  `windows.zig`) resolve correctly.
