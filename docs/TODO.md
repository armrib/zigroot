# TODO

Ordered work list to get `zigroot` from its current state (Phase 0-5, see
`README.md`) to the target behaviour:

- **no CLI arguments**: run `zigroot` in a project directory, it reads
  `build.zig` to find roots and modules;
- **external libraries come from `build.zig.zon`**: a named
  `@import("foo")` that matches a `.dependencies` key is an external
  package, never dead code, never an "unresolved import";
- **test-only code does not count as used**: a declaration referenced only
  from `test` blocks (or only from files reached through a `test` block's
  `@import`) is dead.

Current baseline, measured by running the binary on its own sources with
Zig 0.15.2: 507 dead declarations reported out of roughly 520 symbols. The
tests pass (20/20). Steps are ordered so each one shrinks that number and
can be shipped on its own. Each step lists the files to touch, the ZLint
API it relies on, and the test that proves it.

The semantic layer is our copy of ZLint's (`src/semantic/`, from commit
`8cbbb1c`, see `src/semantic/UPSTREAM.md`). Relevant public surface:

| What | Where |
| --- | --- |
| Symbol flags `s_fn`, `s_fn_param`, `s_payload`, `s_member`, `s_variable`, `s_const`, `s_extern`, `s_export`, `s_struct`, `s_enum`, `s_union`, `s_error` | `src/semantic/Symbol.zig` `Flags` |
| `Symbol.scope`, `Symbol.decl`, `Symbol.visibility` (`.public`/`.private`), `Symbol.members`, `Symbol.exports` | `src/semantic/Symbol.zig` |
| Scope flags `s_top`, `s_function`, `s_struct`, `s_enum`, `s_union`, `s_block`, `s_test`, `s_comptime`; `Scope.parent`; `Scope.Tree.getScope`, `iterParents` | `src/semantic/Scope.zig` |
| `Reference.symbol` (optional, `.none` when unresolved), `Reference.scope`, `Reference.node`, `Reference.identifier` | `src/semantic/Reference.zig` |
| `ModuleRecord.ImportEntry{ specifier, node, kind }` | `src/semantic/ModuleRecord.zig` |
| `Semantic.nodeSpan`, `Semantic.nodeSlice`, `Semantic.getBinding`, `Semantic.resolveBinding` | `src/semantic/Semantic.zig` |
| `visitFieldAccess` is a `// TODO: record references` stub | `src/semantic/Builder.zig:850` |

---

## Step 0 — Quick fixes (bugs found in review)

Small, independent, do them first.

### 0.1 Skip `.zig-cache`, not `zig-cache`

- File: `src/Project.zig`, `discoverZigFiles`, `skip_dirs`.
- Zig 0.13+ writes to `.zig-cache`. Running `zigroot --dir .` today
  reports generated files under `.zig-cache/o/.../dependencies.zig` as
  orphans.
- Change the list to `.git`, `.zig-cache`, `zig-cache`, `zig-out`,
  `vendor`. Better: skip any directory component starting with `.`.
- Test: `Project_test.zig`, create `.zig-cache/x.zig` in the tmp dir and
  assert it is not discovered.

### 0.2 `main` root must be top-level

- File: `src/project/Roots.zig`, `build`.
- `getSymbolNamed("main")` returns the first symbol with that name in
  declaration order, in any scope. A parameter or local named `main`
  declared earlier in the file wins over the real entry point.
- Replace with: iterate `semantic.symbols.iter()`, accept a symbol only if
  `name == "main"`, `flags.s_fn`, and
  `semantic.scopes.getScope(sym.scope).flags.s_top`.
  Alternatively use `semantic.getBinding(root_scope, "main")` with the
  root scope id `@enumFromInt(0)` (see `semantic_reuse_test.zig`).
- Test: file with `fn helper(main: u32) void {}` before `pub fn main()`;
  assert the root is the function.

### 0.3 Surface parse errors

- File: `src/project/File.zig`, `load`.
- `result.errors.deinit(gpa)` throws away parse/semantic errors. A file
  with a syntax error yields a partial symbol table and is then analysed
  as if complete, producing false "dead" reports.
- Keep `result.errors` on `File` (or a count), print them in `main.zig`,
  and return a non-zero exit. Tests should assert the count is zero for
  every fixture.

### 0.4 Docs and naming

- `src/root.zig` mentions `docs/architecture.md`, which
  does not exist. Either write it or drop the reference.
- `src/project/Reachability.zig` says BFS but `queue.pop()` makes it a
  DFS. Either rename to "worklist" in the doc comment or use an index
  cursor for real BFS. Result is identical, only the comment is wrong.
- `SymbolId.eql` duplicates `std.meta.eql`; remove it or keep it as a
  thin wrapper for readability.

---

## Step 1 — Report only declarations

This is the biggest single reduction in noise. Today `deadSymbols`
iterates the whole symbol table, so parameters, locals, loop captures,
struct fields, enum tags and the `_` of a non-exhaustive enum are all
reported.

- New file: `src/project/DeclFilter.zig` (or a function on `Project`):

  ```zig
  pub fn isReportable(semantic: *const Semantic, id: Symbol.Id) bool
  ```

  Returns true when the symbol is a *declaration* a user would delete as
  a unit:
  - `flags.s_fn`, or `flags.s_const`/`flags.s_variable` declared in a
    container scope;
  - the declaring scope (`Symbol.scope`) has `s_top`, `s_struct`,
    `s_enum` or `s_union`, and does **not** have `s_function` or `s_block`;
  - not `flags.s_fn_param`, not `flags.s_payload`, not `flags.s_catch_param`;
  - name is non-empty and not `_`.
- Struct fields and enum tags (`flags.s_member`) are a separate category.
  Do not report them in the default output. They can be an opt-in later
  since deleting a field changes the type's layout and its users.
- `Reachability.deadSymbols` applies the filter. `Roots.build` does not
  need it (an `export` param cannot exist).
- Keep `Reachability.build` walking *all* symbols. A local that references
  a function still creates the edge `enclosing_fn -> function` through
  `OwnerMap`, so filtering only affects reporting, not reachability.
- Test: `Reachability_test.zig`, fixture

  ```zig
  fn f(param: u32) void { const local = param; _ = local; }
  pub fn main() void { f(1); }
  ```

  assert `deadSymbols` is empty.
- Expected effect on the self-run: from 507 to roughly 100.

---

## Step 2 — Exclude test-only code

The user requirement: code used only by tests is dead.

### 2.1 References from `test` blocks already do not count

`test "..." {}` has no symbol, so `OwnerMap.get` returns null for nodes
inside it and `SymbolGraph.build` skips them. Add a test that locks this
in:

```zig
fn only_in_test() void {}
test { only_in_test(); }
pub fn main() void {}
```

assert `only_in_test` is dead. Also cover a `test` block that references a
`comptime` helper.

### 2.2 Do not follow `@import` inside `test` blocks

- File: `src/Project.zig`, `loadRecursive`.
- `root.zig` has `test { _ = @import("Project_test.zig"); ... }`. Those
  imports are recorded in `semantic.modules.imports` like any other, so
  every `*_test.zig` file is loaded and analysed. On the self-run this
  adds 6 files and about 250 "dead" symbols.
- Detection: for each `ImportEntry`, walk `semantic.node_links.getParent`
  from `entry.node` upward; if any ancestor node's tag is `.test_decl`
  (`semantic.nodes().items(.tag)[i]`), the import is test-only. Cheaper
  alternative: find the reference or scope for the node and check
  `Scope.flags.s_test` through `iterParents`.
- Record test-only imports in `ImportGraph` with a new field
  `test_only: bool` on `Edge`, or in a separate `test_imports` list. Do
  **not** load the target file into `Project.files`.
- Orphan detection must not report those files: a file reached only
  through a test import is a *test file*, not an orphan. Add a third
  bucket in the CLI output: "test-only files (not analysed)".
- Test: `Project_test.zig`, `main.zig` with a `test` block importing
  `helper_test.zig`; assert `files.len == 1` and the helper is neither an
  orphan nor loaded.

### 2.3 `_test.zig` naming convention

Optional shortcut: also treat any file whose basename ends in `_test.zig`
as a test file even when imported from a non-test scope. Keep it behind a
constant so it can be turned off.

---

## Step 3 — Read `build.zig` (no CLI arguments)

Goal: `zigroot` with no arguments, run from a directory containing
`build.zig`, discovers everything it needs.

### 3.1 Parse `build.zig` with `std.zig.Ast`

- New file: `src/build/BuildFile.zig`.
- `std.zig.Ast.parse(gpa, source, .zig)` gives the AST. Walk the
  top-level `pub fn build(b: *std.Build)` body only.
- Recognise these call shapes by callee name (field access on any
  receiver, so `b.addExecutable` and `std.Build.addExecutable` both hit):

  | Call | Extract |
  | --- | --- |
  | `b.addExecutable(.{ .name = "x", .root_module = M })` | executable named `x`, root module `M` |
  | `b.addExecutable(.{ .root_source_file = b.path("p") })` (old style) | executable, root file `p` |
  | `b.addLibrary(...)`, `b.addStaticLibrary`, `b.addSharedLibrary` | library, root module or root file |
  | `b.createModule(.{ .root_source_file = b.path("p") })` | anonymous module rooted at `p` |
  | `b.addModule("name", .{ .root_source_file = b.path("p") })` | **exported** module `name` rooted at `p` |
  | `M.addImport("name", N)` | module `M` can `@import("name")`, resolved to module `N` |
  | `b.addTest(.{ .root_module = M })` / `.root_source_file` | test root, used only to know which files are test entry points |
  | `b.dependency("dep", .{})` then `.module("m")` | external module `m` from package `dep` |

- Track local `const` bindings inside `build` so `const mod = b.createModule(...)`
  followed by `exe.root_module.addImport("zigroot", mod)` resolves.
  A tiny name → value map over the function body is enough. Do not try
  to evaluate anything else; if a value is not a recognised call or a
  known local, record it as unknown and continue.
- `b.path("relative")` resolves relative to the directory of `build.zig`.
- Output structure:

  ```zig
  pub const Module = struct {
      name: ?[]const u8,          // null for anonymous createModule
      root_source_file: ?[]const u8,
      imports: std.StringHashMapUnmanaged(ModuleRef), // "zlint" -> external, "zigroot" -> local module id
      kind: enum { local, external }, // external = from b.dependency(...).module(...)
  };
  pub const Artifact = struct {
      kind: enum { exe, lib, @"test" },
      name: []const u8,
      root: ModuleRef,
  };
  ```

- Test: fixture copies of this project's own `build.zig` plus an old-style
  `addExecutable(.{ .root_source_file = ... })` one. Assert the two
  artifacts, the `zigroot` module, and the `zlint` import.

### 3.2 Derive roots from artifacts

- File: `src/Project.zig` gains `pub fn fromBuild(gpa, build: *const BuildFile) !Project`.
- Every `exe` artifact's root module file is an `executable_entry` root.
- Every `lib` artifact and every `b.addModule` (exported module) root
  file is a **library root**: its `pub` declarations, and transitively
  every `pub` declaration reachable through `pub const x = @import(...)`
  re-exports, are roots of kind `public_api`. See Step 5.
- `addTest` roots are recorded but produce no reachability roots (test
  code does not count). They are used by Step 2 to classify files.
- Scan directory for orphan detection defaults to the directory of
  `build.zig`; also skip `zig-out`, `.zig-cache`, `vendor`, and every
  path listed as a `.path` dependency in `build.zig.zon` (Step 4).

### 3.3 CLI

- File: `src/main.zig`.
- Remove `--root` and `--dir`. Locate `build.zig` by walking up from the
  current directory. Exit with a clear error if none is found.
- Keep one escape hatch for debugging, e.g. the environment variable
  `ZIGROOT_BUILD=/path/to/build.zig`, so tests and CI can point at
  fixtures. No other flags.
- Output sections: parse errors, external modules detected, test-only
  files skipped, orphan files, dead declarations (with `file:line:col`
  via `semantic.nodeSpan(sym.decl)`).
- Exit code: 1 if any orphan or dead declaration, 2 on load/parse error.
- Update `README.md` "Run" section.

---

## Step 4 — Read `build.zig.zon` (external libraries)

- New file: `src/build/ZonFile.zig`.
- Parse with `std.zon.parse.fromSlice` into a struct with only the fields
  we need (`name`, `dependencies` as a map of `{ url, hash, path, lazy }`),
  using `.ignore_unknown_fields = true`. Fall back to `std.zig.Ast.parse`
  with `.zon` mode if the typed parse proves too rigid (dependency values
  are structs with optional fields, which `std.zon.parse` handles).
- Result: set of dependency names, and for each `.path` dependency, the
  directory to exclude from orphan scanning.
- Wire into `Project.loadRecursive`: a `.module` import whose specifier is
  `std`, `builtin`, `root`, a `build.zig.zon` dependency name, or a name
  from any `addImport` on the owning module, is classified `external` and
  never printed as unresolved. Anything else stays `unresolved` and is
  printed, since that is a real configuration gap.
- `ImportGraph.UnresolvedImport` gains `reason: enum { external, unknown_module, not_a_zig_file, load_failed }`.
- Important: an external module is a **reachability sink**, never a
  source of roots. Nothing in `zlint` can make a `zigroot` declaration
  reachable.
- Test: fixture zon with `.zlint = .{ .path = "vendor/zlint" }` and one
  URL dependency; assert both names are external and `vendor/zlint` is
  excluded from discovery.

---

## Step 5 — `pub` policy and library roots

- File: `src/project/Roots.zig`.
- Add `RootKind.public_api` population: for each library root file (Step
  3.2), every symbol with `visibility == .public` whose declaring scope is
  `s_top` is a root.
- Re-exports: a `pub const Foo = @import("foo.zig");` at top level of a
  library root makes `foo.zig` a library root too. Same for
  `pub const Foo = @import("foo.zig").Foo;` once Step 7 resolves member
  access. Compute this as a fixpoint over `ImportGraph` edges whose source
  declaration is `pub` and top-level.
- Executable roots do **not** get `public_api` roots. In an executable,
  `pub` is just visibility.
- Test: `lib.zig` with `pub fn api()`, `fn internal()`, and
  `pub const sub = @import("sub.zig")`; assert `api` and `sub.zig`'s pub
  functions are reachable, `internal` is dead.

---

## Step 6 — Cross-file resolution

Today `main.zig`'s `Project` binding resolves inside `main.zig` only, and
nothing in `Project.zig` is reachable.

- New file: `src/project/Resolver.zig`.
- Input per file: the `ImportGraph` edge (import node → target `FileId`)
  and the local symbol bound to that import. Find the binding by taking
  the import node's parent chain up to a `simple_var_decl`/`global_var_decl`
  whose init expression is the `@import` call, then look up the symbol
  whose `decl` is that node.
- Store `import_bindings: AutoHashMap(SymbolId, FileId)` on `Project`.
- Member access on an import binding: `storage.start()` is a
  `.field_access` node whose LHS is an identifier reference to `storage`.
  ZLint records the reference to `storage` (with `Reference.node` being
  the identifier). Take the reference node's parent; if it is
  `.field_access`, read the field token name, look up
  `target_file.semantic.getBinding(root_scope, name)`, and add a
  `SymbolGraph` edge `owner -> { target_file, symbol }`.
- Chained access `a.b.c` where `a` is an import: resolve `b` in the target
  file, then continue with Step 7 rules.
- `@import("x.zig").foo` with no binding (inline use): the `@import` node's
  parent is the `.field_access`; same lookup, owner comes from `OwnerMap`.
- The cross-file edges live in a project-wide `SymbolGraph` on `Project`
  (rename the per-file one or merge them: `Reachability.build` must
  consult both).
- Test: `main.zig` imports `storage.zig` and calls `storage.start()`;
  `storage.zig` has `pub fn start()` and `pub fn unused()`. Assert `start`
  reachable, `unused` dead.

---

## Step 7 — Container member resolution

ZLint's `visitFieldAccess` records no references. Every method call in a
Zig codebase (`opts.deinit()`, `FileId.index(x)`, `Options.deinit`) is
therefore invisible today.

### 7.1 Static access `Type.member`

- File: `src/project/Resolver.zig`.
- When a `.field_access` LHS resolves to a symbol with `flags.s_struct`,
  `s_enum` or `s_union`, look up the field name in `Symbol.exports`
  (static members: functions, consts, enum tags) then `Symbol.members`
  (fields). ZLint already fills both lists.
- Nested: `Outer.Inner.run()` resolves left to right.
- Add edge `owner -> resolved member`.
- Test: `const Foo = struct { pub fn bar() void {} fn baz() void {} };`
  with `Foo.bar()` in `main`; `bar` reachable, `baz` dead.

### 7.2 Instance access `value.method()`

- Needs the declared type of `value`. Do **not** implement type inference.
- Cheap cases that cover most code, in this order:
  1. `value` is a parameter or local with an explicit type annotation
     `x: Foo` or `x: *Foo`; read the type node, resolve it as a static
     symbol, then apply 7.1 on `members`.
  2. `value` is `self` inside a function declared in a container scope;
     the container is the enclosing `s_struct` scope's symbol.
  3. `value` is a local initialised by `Foo.init(...)` or `Foo{...}` where
     `Foo` resolves statically.
- Anything else: record the call site as `EdgeKind.unknown` (Step 8).
  Conservative default for `unknown` in the report: mark every member
  named `method` on every container in the project as
  *possibly-reachable* rather than dead. Precision is lower but a wrong
  "dead" is worse than a missed one.
- Test: `var s: Server = ...; s.run();` and a `self.helper()` call.

### 7.3 Patch the semantic layer directly

`src/semantic/` is our own copy, so recording field-access references in
`Builder.visitFieldAccess` is a normal commit (list it in
`src/semantic/UPSTREAM.md`). That would remove most of 7.1 and 7.2's AST
walking; evaluate once the resolver grows past a few hundred lines.

---

## Step 8 — Edge confidence and `extern`

- File: `src/project/SymbolGraph.zig`, add `kind: EdgeKind` to `Edge`,
  `EdgeKind = enum { definite, possible, unknown }`.
- `definite`: identifier reference, static member access, cross-file
  resolved import.
- `possible`: instance method resolved by name match across containers
  (Step 7.2 fallback).
- `unknown`: `@field(T, name)`, function pointers stored in structs, comptime
  generated names. Record the call site but no target.
- `Reachability` runs twice: definite-only and definite+possible. Report
  buckets: "dead" (unreachable in both), "possibly dead" (reachable only
  through `possible` edges). No flag; always print both buckets.
- `extern fn`/`extern var` (`flags.s_extern`) are declarations of
  something defined elsewhere; never report them dead. Filter in Step 1's
  `isReportable`.
- `comptime` blocks at container level (`comptime { _ = x; }`) reference
  symbols without being a declaration: treat a top-level `comptime` block
  like a root, since Zig evaluates it when the container is analysed.
  `std.testing.refAllDecls(@This())` inside a `test` block stays
  test-only (Step 2).

---

## Step 9 — Reporting quality

- Print `path:line:col: kind name` using `semantic.nodeSpan(sym.decl)` and
  a line-index built once per file (ZLint's `Span` is byte offsets).
- Group by file, sort by line.
- Collapse dead reference cycles (Tarjan SCC over `SymbolGraph`) into one
  finding with the cycle listed, so `dead_a -> dead_b -> dead_a` is one
  line, not two.
- Make paths relative to the `build.zig` directory.
- Exit codes and section order as in Step 3.3.

---

## Step 10 — Validation on real code

- Self-run target: after Steps 0-7, running `zigroot` in this repo should
  report zero dead declarations except the genuinely unused ones
  (`SymbolId.eql` if kept, `ImportGraph.outgoing` (only `SymbolGraph.outgoing` is called), `Roots.RootKind.configured`
  and `.@"test"` tags). Write that list down as the expected output and
  add an integration test that runs the binary on the repo itself and
  compares.
- Second target: run on `vendor/zlint` (has exe + lib + tests, many
  containers and instance calls). Manually check a sample of 20 reported
  declarations; the goal is zero false positives in the "dead" bucket,
  false negatives are acceptable in "possibly dead".
- Multi-target files (`linux.zig` vs `windows.zig` behind
  `switch (builtin.os.tag)`): both branches of a comptime switch get
  visited by ZLint, so both files are reachable. Document that this is
  intentional: platform-specific code is not dead.

---

## Out of scope for now

- Real type inference for instance method calls.
- Generic instantiation tracking (`fn List(comptime T: type)` members).
- `@embedFile`, `@cImport`.
- Watching mode, LSP integration, auto-delete.
