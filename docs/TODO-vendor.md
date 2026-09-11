# TODO — Inline ZLint's semantic layer

Goal: stop depending on the `vendor/zlint` submodule and its three
transitive packages. Copy only the `Semantic` layer into this repo, strip
what it does not need, and credit ZLint in the README.

Why:

- `zig build --fetch` today needs `smart_pointers`, `chameleon` and
  `recover` from GitHub, none of which the analyser uses. The analyser
  uses about 3,600 lines of ZLint out of a much larger linter.
- The submodule is pinned to a pre-Zig-0.16 commit. Owning the code means
  the Zig version migration is ours to schedule, not upstream's.
- `Symbol`, `Scope` and `Builder` need changes for `docs/TODO.md` Step 7
  (`visitFieldAccess` records no references). Patching a submodule means
  a fork; patching our own copy is a normal commit.

Measured on commit `8cbbb1c`:

| Piece | Lines | Needed |
| --- | --- | --- |
| `src/Semantic.zig` + `src/Semantic/*.zig` (12 files) | 3,606 | yes |
| `src/Semantic/test/*.zig` (8 files) | 1,747 | yes, keep as regression tests |
| `src/util/id.zig` (`NominalId`) | 197 | yes |
| `src/util/bitflags.zig` (`Bitflags`) | 206 | yes |
| `src/util.zig` (`assert`, `debugAssert`, `IS_DEBUG`, `RUNTIME_SAFETY`, `@"inline"`) | 69 | partly |
| `src/span.zig` (`Span`, `LabeledSpan`) | 284 | yes |
| `src/Error.zig` (`Error`, `Error.Result`, `newStatic`) | 268 | partly, pulls `smart_pointers` |
| `src/source.zig` (`Source`, `ArcStr`) | 55 | no, only `Builder.withSource` |
| `util/cow.zig`, `util/env.zig`, `util/feature_flags.zig`, `util/debug_only.zig` | ~340 | no |
| `chameleon`, `recover` packages | | no, reporter and CLI only |
| `smart_pointers` package | | no, after `Error.zig` cleanup |

---

## Step 1 — Copy the files

Target layout, keeping ZLint's file names so diffs against upstream stay
readable:

```
src/semantic/
  Semantic.zig          <- vendor/zlint/src/Semantic.zig
  Builder.zig           <- vendor/zlint/src/Semantic/Builder.zig
  Symbol.zig
  Scope.zig
  Reference.zig
  ReferenceStack.zig
  NodeLinks.zig
  ModuleRecord.zig
  Parse.zig
  ast.zig
  builtins.zig
  tokenizer.zig
  Error.zig             <- vendor/zlint/src/Error.zig (trimmed, Step 3)
  span.zig              <- vendor/zlint/src/span.zig
  util.zig              <- vendor/zlint/src/util.zig (trimmed, Step 2)
  util/id.zig
  util/bitflags.zig
  util/bitflags_test.zig
  test/                 <- vendor/zlint/src/Semantic/test/ (all 8 files)
  LICENSE               <- vendor/zlint/LICENSE (MIT, Don Isaac)
  UPSTREAM.md           <- see Step 6
```

- Do a plain copy first, commit, then edit. That keeps the "what came
  from upstream" commit separate from "what we changed".
- Fix relative imports: `@import("../Semantic.zig")` becomes
  `@import("Semantic.zig")`, `@import("../span.zig")` becomes
  `@import("span.zig")`, `@import("Semantic/X.zig")` becomes
  `@import("X.zig")`. `@import("util")` (a named module in ZLint's
  `build.zig`) becomes `@import("util.zig")` everywhere in the copied
  tree; there are 9 sites.
- `src/root.zig`: replace `pub const zlint = @import("zlint");` with
  `pub const zlint = struct { pub const Semantic = @import("semantic/Semantic.zig"); };`
  so the `zlint.Semantic.*` paths used across `src/project/` keep
  compiling unchanged. Rename the alias to `semantic` in a later cleanup.
- `src/main.zig`: drop `@import("zlint")` if unused after the change.

## Step 2 — Trim `util.zig`

Only these are referenced from the semantic tree (counted with grep):

| Symbol | Uses |
| --- | --- |
| `@"inline"` | 10 |
| `assert` | 7 |
| `IS_DEBUG` | 6 |
| `Bitflags` | 3 |
| `debugAssert` | 2 |
| `NominalId` | 2 |
| `RUNTIME_SAFETY` | 1 |

- Keep those, plus `assertUnsafe` if `id.zig` or `bitflags.zig` use it.
  Delete `cow`, `env`, `feature_flags`, `debug_only` and any
  `@import("config")` reference (that was a ZLint build option module).
- `util.zig` has a `test` block that refs the deleted modules; prune it.

## Step 3 — Remove `smart_pointers`

`smart_pointers` enters through `Error.zig` (`source: ?ArcStr`, an
`Arc([:0]u8)` sharing the source text between errors) and `source.zig`.

- `Error.zig`: replace `source: ?ArcStr` with `source: ?[]const u8`
  borrowed from the owning `File.source` (which already outlives
  `semantic`, see `src/project/File.zig`). Delete the `Arc` import and the
  clone/deinit calls on it. `Error.Result(T)` and `newStatic` stay.
- `Builder.zig`: delete `_source_code: ?_source.ArcStr`, `_source_path`,
  and `pub fn withSource(...)`. The `@import("../source.zig")` goes with
  them. `Builder.build(source)` already takes the sentinel slice directly,
  which is the only path `File.load` uses.
- `Semantic.zig`: the `Source` import at line 169 is inside a test helper;
  rewrite that helper to call `Builder.build` on the string directly.
- Do not copy `source.zig`.
- `Error.zig` also imports `json.zig` (for `jsonStringify` on errors,
  used by ZLint's JSON reporter). Delete that method and the import; we
  never serialise errors.
- `span.zig` imports `Semantic.zig` (for a token/node helper) and
  `util`; both stay inside the copied tree, so no change beyond the
  path fix.
- `util/id.zig` and `util/bitflags.zig` import `util` (relative name)
  and `bitflags_test.zig` imports `zlint`; point the first at
  `../util.zig` and rewrite the second to `@import("../Semantic.zig")`
  or drop the assertion that needs it.

## Step 4 — Build files

- `build.zig`: delete `zlint_dep` and both `addImport("zlint", ...)`
  calls. `zigroot_mod` and the exe module get no imports. The test step
  stays on `zigroot_mod`.
- `build.zig.zon`: delete the `.zlint` dependency; `.dependencies` becomes
  empty. `.paths` unchanged.
- `git submodule deinit -f vendor/zlint && git rm -f vendor/zlint`, delete
  `.gitmodules`, delete `vendor/`. `discoverZigFiles` still skips
  `vendor` for user projects; keep that.
- `zig build test` must pass with no network and no `--fetch`. Add that
  as the acceptance check.

## Step 5 — Wire ZLint's semantic tests in

- `src/semantic/Semantic.zig` already has a `test` block importing the
  8 files under `test/`. `test/util.zig` reaches outside the copied
  tree: it imports `../../reporter.zig`, `../../root.zig` and
  `../../source.zig` (checked with grep). Those are used to print
  semantic errors nicely on test failure and to build a `Source`. Replace
  with a plain `std.debug.print` of `Error.message` and a direct
  `Builder.build(src)` call, matching Step 3.
- The strings `foo.zig`, `x.zig`, `build.zig.zon`, `.hidden`, `weird.`
  inside the test files are `@import` fixtures under test, not real
  imports; leave them alone.
- Add `_ = @import("semantic/Semantic.zig");` to the `test` block in
  `src/root.zig` so `zig build test` runs them. Expect the test count to
  go from 20 to roughly 20 plus ZLint's semantic tests; record the number
  in the commit message.
- `src/semantic_reuse_test.zig` was written to detect upstream API
  drift. Once the code is inlined there is no upstream; either delete it
  or rename it to make clear it now tests our own copy.

## Step 6 — Provenance

- `src/semantic/UPSTREAM.md`: one paragraph. Copied from
  `https://github.com/DonIsaac/zlint` at commit
  `8cbbb1c9c48ebc091d9b230bb98355d53cc251ad`, MIT licensed, list of
  local modifications (Step 2, Step 3, plus every later change such as
  `visitFieldAccess`). Update the list whenever the tree is edited.
- Keep `src/semantic/LICENSE` verbatim. MIT requires the copyright notice
  and permission notice to travel with the code.
- `README.md`: replace the "Zig version" section and the submodule
  mention with a short "Credits" section:

  > The per-file semantic analysis under `src/semantic/` is copied from
  > ZLint by Don Isaac (MIT), commit `8cbbb1c`, and modified. See
  > `src/semantic/UPSTREAM.md` for the list of changes.

  Update the "Build" section: `zig build --fetch` is no longer needed.
  Update the "Layout" section: drop `vendor/zlint/`, add `src/semantic/`.
- `docs/TODO.md`: the API table refers to `vendor/zlint/src/Semantic/...`
  paths; change them to `src/semantic/...`. Step 7.3 ("patch ZLint")
  becomes the default plan rather than an alternative.

## Step 7 — Zig 0.16 (after the above, optional)

With the code inlined, the reason for the pre-0.16 pin is gone. The
semantic tree only uses `std.zig.Ast`, `std.zig.Tokenizer`, allocators,
`MultiArrayList` and hash maps. Migrate when ready; nothing in the copied
tree touches the filesystem, which was the part of upstream that moved
to the `Io` API.

---

## Order and checkpoints

1. Copy + import fixes, build passes, tests 20/20. Commit.
2. Trim `util.zig`. Commit.
3. Remove `smart_pointers` from `Error.zig`/`Builder.zig`. Commit.
4. Delete submodule, dependency, and `--fetch` from docs. Fresh clone
   builds offline. Commit.
5. ZLint semantic tests running under `zig build test`. Commit.
6. `UPSTREAM.md`, `LICENSE`, README credits. Commit.

Total expected size of `src/semantic/`: about 4,100 lines of source and
about 1,900 lines of tests.
