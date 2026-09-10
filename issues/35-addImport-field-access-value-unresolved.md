# `addImport`'s value argument isn't resolved when it's a field access into a returned modules-struct

`BuildGraph`'s scan handles `<mod>.addImport("name", value)` by resolving
`value` back to a path via `pathForBinding`, which only handles the case
where `value` is a bare `.identifier` bound earlier in the *same file*
by `const value = b.createModule(...)` (or `b.path(...)`, via
`bindings`). If `value` is instead a field access — `helper.field` —
`pathForBinding` returns `null` immediately (`tree.nodeTag(value_node)
!= .identifier`) and the whole `addImport` call is silently dropped, so
that name never enters `result`.

That's exactly the shape used when a `build.zig` factors module wiring
into a helper function that builds several related modules and returns
them bundled in a struct, then the call site wires each one onto the
final executable by field access:

```zig
fn wireModules(b: *std.Build, ...) Mods {
    const auth_handler = b.createModule(.{ .root_source_file = b.path("src/AuthHandler.zig"), ... });
    // auth_handler is only ever the *receiver* of .addImport calls here
    // (auth_handler.addImport("http", http) etc.), never the *value* of
    // one under its own name "auth_handler" — nothing inside this
    // function does `.addImport("auth_handler", auth_handler)`.
    return .{ .auth_handler = auth_handler, ... };
}

pub fn build(b: *std.Build) void {
    const mods = wireModules(b, ...);
    const exe = b.addExecutable(...);
    exe.root_module.addImport("auth_handler", mods.auth_handler); // value_node is a field_access — dropped
}
```

`main.zig`'s `@import("auth_handler")` then has no entry in `result` to
resolve against and stays unresolved — unless the same name happens to
*also* get registered as a plain-identifier `addImport` value somewhere
else in the file (e.g. another module importing the same dependency
under the same name), which is why this doesn't affect every module
uniformly: it only surfaces for modules that are exclusively wired onto
the final exe by field access and never separately re-imported under
their own name by identifier elsewhere in the file.

Measured against `formic/backend`
(`zigroot --root apps/iamd/src/main.zig --dir backend --build-zig
build.zig`, run from `backend/`): `apps/iamd/build.zig`'s `wireModules`
returns an `Iamd` struct; `apps/iamd/src/main.zig` does
`iam_exe.root_module.addImport("auth_handler", iam_mods.auth_handler)`
(and the same for `admin_api`, `iam_auth`, `service_api`, `lifecycle`).
All five stay unresolved — `main.zig: @import("auth_handler") [module]`
etc. — while ~25 sibling modules wired the exact same way (`config`,
`storage`, `http`, ...) happen to resolve anyway, purely because they're
*also* passed as a plain-identifier `addImport` value somewhere inside
`wireModules` itself (e.g. `service_api.addImport("config", config)`),
which is what actually registers them in `result`.

Minimal repro:
```zig
// build.zig
const Mods = struct { foo: *std.Build.Module };

fn wireModules(b: *std.Build) Mods {
    const foo = b.createModule(.{ .root_source_file = b.path("src/foo.zig") });
    return .{ .foo = foo };
}

pub fn build(b: *std.Build) void {
    const mods = wireModules(b);
    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
    }) });
    exe.root_module.addImport("foo", mods.foo);
}
```
`zigroot --root src/main.zig --dir src --build-zig build.zig` leaves
`src/main.zig: @import("foo")` unresolved even though `foo` is a real,
unambiguous local module.

Fix sketch: extend `pathForBinding` (or add a sibling resolved
alongside it in the `addImport` handling loop) to also handle a
`field_access` `value_node`: pull the field name, then look it up in a
per-function-return tracking map — the natural way is to recognize
`return .{ .foo = foo, ... }` struct-literal returns the same way
`nameAndRootSourceFileOfAddModule`/`rootSourceFileOfCreateModule`
already inline through single-expression helper functions, binding each
field name to whatever `pathForBinding` resolves for its value
expression, then extend `bindings` (or a parallel map) with `<callee
name>.<field> -> path` keyed off the call site's assigned variable name
(`mods` in `const mods = wireModules(b)`), so `mods.foo` resolves the
same way a direct identifier does.
