# `createModule` hidden behind a cross-file helper call that returns the module directly is unresolved

`rootSourceFileOfCreateModule` only matches an inline `<ident>.createModule(...)`
call (or a same-file pass-through helper resolved via `pathThroughHelperCall`,
which itself only handles a helper whose body is `return b.path(...);` — a
*path*, not a module). `bindStructReturnFields` handles the other
already-known factoring shape, a same-file helper `return .{ .foo = foo,
... };` bundling several modules in a struct — but it too only looks up the
callee via `findFnDecl(tree, fn_name)`, which searches only the *current*
file's AST, and only matches a bare-identifier callee (`fn_expr` must be
`.identifier`), not a field access into another local `@import`ed file's
namespace.

Neither path covers a helper, declared in a different file and called via
that file's namespace, whose body is a single `return b.createModule(...);`
(i.e. the module itself is the return value, not a struct of modules):

```zig
// build/vendor.zig
pub fn yamlModule(b: *std.Build, target: ..., optimize: ...) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("libs/yaml/yaml.zig"), ... });
}
```
```zig
// build.zig
const vendor = @import("build/vendor.zig");
...
const yaml_mod = vendor.yamlModule(b, target, optimize);
main.addImport("yaml", yaml_mod);
```

`fullCall(init_node)` succeeds for `vendor.yamlModule(...)`, but
`nameAndRootSourceFileOfAddModule` (looks for `.addModule(...)`, wrong
callee) and `bindStructReturnFields` (looks for a same-file, identifier-
named function returning a struct literal) both decline, so `yaml_mod`
never enters `bindings`, and every `addImport("yaml", yaml_mod)` wired off
it is dropped from `result`.

Measured against `formic/backend` (`zigroot --root
apps/clusterd/src/main.zig --dir backend --build-zig build.zig`, run from
`backend/`): `build/vendor.zig`'s `yamlModule` factory is shared by every
app that touches YAML config (`clusterd`, `iamd`, `staticd`, ...); `@import("yaml")`
stays unresolved in all ~10 files under `libs/yaml/` and every consumer
that imports it (30 unresolved-import lines total in the merged run across
all app roots).

Minimal repro:
```zig
// helper.zig
pub fn fooModule(b: *std.Build) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/foo.zig") });
}
```
```zig
// build.zig
const helper = @import("helper.zig");
pub fn build(b: *std.Build) void {
    const foo = helper.fooModule(b);
    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
    }) });
    exe.root_module.addImport("foo", foo);
}
```
`zigroot --root src/main.zig --dir . --build-zig build.zig` leaves
`src/main.zig: @import("foo")` unresolved even though `foo` is a real,
unambiguous file.

Fix sketch: generalize the existing pass-through-helper machinery
(`pathThroughHelperCall`, `bindStructReturnFields`) into one lookup that,
given a call's callee (bare identifier *or* `<local-file-alias>.<fn>` field
access resolved through the already-tracked `file_imports`/recursion
machinery `Project.loadBuildGraphFile` uses), finds the callee's `fn_decl`
in whichever file it's actually defined in, and — if that function's body
is a single `return b.createModule(...);` (or a chain of statements ending
in one, same relaxation `passThroughPathParamIndex` already allows for the
path-only case) — binds the call-site variable straight to the extracted
`root_source_file` path, the same way an inline `createModule` call would.
This likely means `parseInto` needs a second pass (or a shared, mutable
`fn_decls: file -> AST` map threaded through the recursive `Project`
scan) so a helper defined in a sibling file that's scanned *after* its
call site is still found — right now `bindStructReturnFields`'s doc
comment already notes it "relies on the helper being scanned ... before
its call site is reached," which cross-file calls make less reliable
since file scan order isn't guaranteed to put the definition first.
