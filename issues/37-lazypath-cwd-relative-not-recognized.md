# `.root_source_file = .{ .cwd_relative = ... }` isn't recognized as a resolvable path

`rootSourceFileFromOptions` only recognizes a `root_source_file` field
whose value is a call whose callee field-accesses to `path` (i.e.
`b.path("...")`, or a pass-through helper that ends in `b.path(...)`):

```zig
fn rootSourceFileFromOptions(tree: *const Ast, options: Ast.Node.Index, struct_buf: *[2]Ast.Node.Index) ?Ast.TokenIndex {
    const struct_init = tree.fullStructInit(struct_buf, options) orelse return null;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_source_file")) continue;
        var inner_buf: [1]Ast.Node.Index = undefined;
        const path_call = tree.fullCall(&inner_buf, field_value) orelse return null;
        ...
```

`tree.fullCall` on the field's value expects a call node. `std.Build.LazyPath`
has more than one valid literal shape though — `.{ .cwd_relative = "..." }`
(an absolute, or here CLI-cwd-relative, path) is a plain struct literal,
not a call, and `b.pathFromRoot("...")` (used to *build* a `.cwd_relative`
path from something rooted a directory or two above `b`'s own root) is a
call to a different `Build` method than `path`. Neither shape is a
`fullCall`-then-`fieldAccessName == "path"` node, so `rootSourceFileFromOptions`
returns `null` immediately (or, when the whole field value isn't a call at
all, `tree.fullCall` itself returns `null`) and the enclosing `createModule`
is dropped — `bindings` never gets an entry for that variable, so every
later `addImport("name", that_var)` referencing it silently fails to
register `name` in `result`.

Measured against `formic/backend` (`zigroot --root
apps/clusterd/src/main.zig --dir backend --build-zig build.zig`, run from
`backend/`): `apps/clusterd/build.zig`, `apps/iamd/build.zig`, and
`apps/iam-cli/build.zig` each do

```zig
const iam_verify_mod = b.createModule(.{
    .root_source_file = .{ .cwd_relative = b.pathFromRoot("../sdks/iam/zig/iam-verify.zig") },
    .target = target,
    .optimize = optimize,
});
main.addImport("iam_verify", iam_verify_mod);
```

so `@import("iam_verify")` stays unresolved everywhere it's used (9
call sites across `apps/clusterd/src/transport/http/{auth,authz}.zig`,
`domains/provisioning/iam_*.zig`, `domains/controlplane/Server.zig`),
even though the target file (`sdks/iam/zig/iam-verify.zig`) is a real,
unambiguous local file one directory above the backend package root —
it's just spelled with `.cwd_relative` + `pathFromRoot` instead of
`b.path`, because it lives outside the tree `b.path` (relative to
`build.zig`'s own directory) can reach directly.

Minimal repro:
```zig
// build.zig
pub fn build(b: *std.Build) void {
    const foo = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathFromRoot("../shared/foo.zig") },
    });
    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
    }) });
    exe.root_module.addImport("foo", foo);
}
```
`zigroot --root src/main.zig --dir . --build-zig build.zig` leaves
`src/main.zig: @import("foo")` unresolved even though `foo` is a real,
unambiguous file.

Fix sketch: extend `rootSourceFileFromOptions` to also recognize a
`root_source_file` field whose value is a struct literal with a
`.cwd_relative` field bound to a string literal (direct case), and to
walk through a `b.pathFromRoot("...")` call the same way it already
walks through a locally-defined pass-through helper — the argument to
`pathFromRoot` is relative to the build root exactly like `b.path`'s
argument is relative to `build.zig`'s directory, so once the string
literal is extracted, the existing `build_graph_dir`-relative resolution
in `Project.resolveViaBuildGraph` should just work (`pathFromRoot`'s
argument can walk above the build root with `../`, same as any relative
path passed to `std.fs.path.resolve`).
