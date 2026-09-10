# A `build.zig` helper wrapping `b.path(...)` breaks all module resolution

```zig
// build.zig
fn srcPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    return b.path(sub_path); // e.g. also validates the path exists first
}

pub fn build(b: *std.Build) void {
    const helper_mod = b.createModule(.{
        .root_source_file = srcPath(b, "src/helper.zig"), // not b.path(...) directly
        // ...
    });
    // ... .addImport("helper", helper_mod) on the exe's root module ...
}
```

`--build-zig build.zig` resolves nothing for this module: `@import("helper")`
in `src/main.zig` stays unresolved and `src/helper.zig` is reported as an
orphan file, even though it's the exe's only non-root-namespace import and
is trivially reachable via `build.zig`'s wiring.

Found running zigroot against formic's workflow backend, whose
`build.zig` defines a `srcPath(b, sub_path)` helper (adds an
existence-check panic on top of `b.path`) and uses it for every
`root_source_file` — 26 of `workflow`'s ~28 local modules never resolve,
leaving 43 files under `src/` orphaned and every cross-module symbol in
`main.zig` (`@import("config")`, `@import("engine")`,
`@import("scheduler")`, etc.) unresolved. Minimally reproduced with the
single-indirection shape above (one helper, one module).

Root cause: `BuildGraph.extractRootSourceFile`
(`src/BuildGraph.zig`) only recognizes `.root_source_file = <ident>.path("...")` —
`parse`'s call-node scan (`fieldAccessName(tree, path_call.ast.fn_expr)`,
checked `== "path"`) requires the value expression to be a *direct* call
to a `.path` method. A `.root_source_file` value that's a call to any
other function — even a one-line pass-through to `b.path` — doesn't
match, and `parseCreateModule` treats the whole `createModule` call as
unresolvable, so the binding (and everything chained off it via
`addImport`) is silently dropped. This is already flagged as a
"best-effort... not a real evaluation" scan in the module doc comment,
but a bare wrapper function is a small enough indirection that it's
worth handling explicitly rather than falling entirely into the
`b.dependency(...)`-style "genuinely can't be resolved without running
the script" bucket.

Fix sketch: extend `extractRootSourceFile` to also recognize a
single-argument call to a *locally-defined* function (found via
`Ast.fnProto`/a top-level `fn` decl in the same file) whose body is
exactly `return b.path(<param>);` (or an equivalent single-expression
body) — inline through it to the same string-literal extraction already
used for the direct `b.path("...")` case. Doesn't need to handle
arbitrary helper bodies, just the common "add a side effect and
delegate" pass-through shape; anything more complex stays unresolved as
today.
