# A module published with `b.addModule("name", .{...})` stays unresolved

```zig
pub fn build(b: *std.Build) void {
    const compiler_mod = b.addModule("compiler", .{
        .root_source_file = b.path("src/root.zig"),
    });
    const exe = b.addExecutable(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "compiler", .module = compiler_mod },
            },
        }),
    });
    b.installArtifact(exe);
}
```

With `src/main.zig` containing `@import("compiler")`, `--build-zig build.zig`
leaves `@import("compiler")` unresolved and `src/root.zig` (plus everything
it re-exports) reported orphaned/dead, even though `compiler_mod` is
plainly wired into `exe`'s module graph by name.

Found running zigroot against formic's `foundry` backend: `build.zig`
publishes its two modules with `b.addModule("db_compiler", .{
.root_source_file = b.path("db-compiler/src/root.zig"), ... })` /
`b.addModule("db_runtime", ...)`, each wired into `db-compiler/src/main.zig`
via an inline `.imports = &.{ .{ .name = "db_compiler", .module =
compiler_mod }, ... }`. Because `db_compiler` never resolves, `main.zig`'s
`db_compiler.parser.parse(...)`, `db_compiler.semantic.analyze(...)`,
`db_compiler.codegen.generate(...)`, `db_compiler.docs.generate(...)` calls
all stay unresolved, and `db-compiler/src/root.zig`'s `token`/`lexer`/`ast`/
`parser`/`semantic`/`layout`/`codegen`/`docs` re-export bindings are all
reported dead — the entire compiler pipeline the actual CLI runs looks
unreachable.

Root cause: `BuildGraph.parse` (`src/BuildGraph.zig`) only recognizes a
module bound to a local variable via `rootSourceFileOfCreateModule`, which
matches calls named exactly `createModule` (`src/BuildGraph.zig:139`,
`if (!std.mem.eql(u8, field, "createModule")) return null;`). The
`var_decl` branch that populates `bindings` (`src/BuildGraph.zig:77-87`)
never fires for `const x = b.addModule("name", .{...})`, so `x` never
becomes a known binding — the subsequent `addImport("name", x)` call or
`.imports = &.{ .{ .name = "name", .module = x } }` field
(`scanImportsField`) then can't find `x` in `bindings` either
(`pathForBinding` looks it up and comes back empty), and `"name"` never
makes it into `result.modules`.

Fix sketch: `b.addModule("name", .{ .root_source_file = ... })` both names
*and* creates the module in one call — no `addImport`/`.imports` wiring is
even required for other files in the same package to `@import("name")` it
(that's exactly its purpose: publishing a named module). `BuildGraph.parse`
needs a second recognized shape alongside `createModule`: a call to
`addModule` whose first argument is a string literal and second is a
`.{ .root_source_file = ... }` struct matching the same
`root_source_file`-field extraction `rootSourceFileOfCreateModule` already
does — feeding `import_name`/`rel_path` straight into `addModulePath`
(`src/BuildGraph.zig:114`), the same sink the `addImport` branch uses,
without needing a `bindings` entry at all (unless the returned module is
*also* later assigned to a var and wired elsewhere via `addImport`/
`.imports`, which should still work by additionally recording the
binding the way the `var_decl` branch does for `createModule`).
