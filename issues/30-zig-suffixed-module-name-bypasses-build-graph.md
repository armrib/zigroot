# `.zig`-suffixed named-module imports never consult `--build-zig`

`Project.loadRecursive` picks its resolution strategy purely from
`entry.kind`, which ZLint's semantic layer sets from the import
specifier's own shape: anything ending in `.zig` is `.file` (a relative
sibling-path import), anything else is `.module` (looked up in
`build_graph`). The `.file` branch (`src/Project.zig:198-214`) always
resolves by joining the specifier onto the *importing file's own
directory* — it never calls `self.build_graph.resolve(...)`, unlike the
`.module` branch just above it.

That's wrong when a `build.zig` deliberately binds a `.zig`-suffixed
string as a named module via `addImport("name.zig", some_module)`
pointing at a file that *isn't* a sibling of the importer — legal Zig
(`@import` resolves through the *compilation's* module table before
ever touching the filesystem relative to the importing file), and a
real pattern in `formic/backend/apps/fuse-shim`: `main.zig` does
`@import("handlers.zig")` / `@import("inode_table.zig")` /
`@import("xattr_filter.zig")`, but those files physically live under
`domains/fuse/`, not `apps/fuse-shim/src/` alongside `main.zig`. The
project's own `build.zig` comment spells out the intent: "handlers.zig's
own `@import("inode_table.zig")`/`@import("xattr_filter.zig")` must
resolve as these SAME named deps here, not fall through to a relative
file lookup."

Measured:
```
zigroot --root apps/fuse-shim/src/main.zig --dir . --build-zig build.zig
```
(run from `formic/backend`) reports all four imports
(`handlers.zig`, `inode_table.zig` ×2, `xattr_filter.zig`) as
`[file]`-kind unresolved, even though `build.zig` registers exactly
those names via `fuse_shim_mod.addImport("handlers.zig", ...)` etc. and
`BuildGraph.parse` already captures the binding correctly (confirmed:
`.module`-kind imports in the same run, e.g. `fuse_abi`/`fv_proto`,
resolve fine through the identical `--build-zig`). The sibling-path
guess in the `.file` branch also silently fails first — `apps/fuse-shim/src/handlers.zig`
doesn't exist — so there's no ambiguity to arbitrate, just a resolver
that was never consulted.

Fix sketch: in the `.file` branch, when the plain sibling-relative
lookup doesn't exist on disk (or unconditionally, before the sibling
lookup — matching real `@import` semantics, where a build-registered
module name always wins over a same-named sibling file), fall back to
`build_graph.resolve(entry.specifier)` the same way the `.module` branch
already does.
