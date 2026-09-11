# A module/path value forwarded through an `Options`-struct field into another file's `wire` function is unresolved

`formic/backend` (and most of its sibling apps under `apps/`) follow a
"backend-layout ticket 18" convention: `backend/build.zig` is a thin
aggregator, and each app owns a `apps/<name>/build.zig` with a `pub const
Options = struct { ... }` and a `pub fn wire(b: *std.Build, opts: Options)
...` that the aggregator calls as `<alias>.wire(b, .{ .field = value, ...
})`. Any module or path value created in the aggregator and threaded into
one of these `Options` structs stays unresolved wherever the callee
dereferences it as `opts.<field>` — `BuildGraph` never connects an
`Options` struct's field to the value supplied at a specific call site.

Two concrete shapes of this in `formic/backend`:

1. **A `*std.Build.Module` value threaded through, then handed straight to
   `addImport`.** `backend/build.zig`:
   ```zig
   const vendor = @import("build/vendor.zig");
   const yaml_mod = vendor.yamlModule(b, target, optimize);
   const cd = clusterd_build.wire(b, .{
       ...
       .yaml_mod = yaml_mod,
       ...
   });
   ```
   `apps/clusterd/build.zig`:
   ```zig
   pub const Options = struct {
       ...
       yaml_mod: *std.Build.Module,
       ...
   };
   pub fn wire(b: *std.Build, opts: Options) Clusterd {
       ...
       const yaml_mod = opts.yaml_mod;
       ...
       main.addImport("yaml", yaml_mod);       // line 58
       domains_hub.addImport("yaml", yaml_mod); // line 373
       pack_test_mod.addImport("yaml", yaml_mod); // line 1084
   }
   ```
   `vendor.yamlModule` itself *is* the exact shape issue 38 fixed (a
   cross-file helper whose body is `return b.createModule(...);`), so
   `yaml_mod` resolves fine as a same-file binding inside
   `backend/build.zig` — but `clusterd_build.wire`'s `opts.yaml_mod` is a
   field access on a function *parameter*, not a traceable local variable,
   so it never enters `bindings` in `apps/clusterd/build.zig`'s own scan.

2. **A path string threaded through, then handed to `b.path(...)` inside a
   shared factory.** `backend/build.zig`:
   ```zig
   const CODEGEN_FRONTENDS = [_]codegen_factory.CodegenOptions{
       .{ .name = "dashboard", .routes_src = "apps/clusterd/src/tools/codegen_routes.zig", ... },
       .{ .name = "iam", .routes_src = "apps/iamd/src/tools/codegen_routes.zig", ... },
   };
   for (CODEGEN_FRONTENDS) |fe| {
       const cg = codegen_factory.addCodegen(b, optimize, test_runner, test_filter, fe);
       ...
   }
   ```
   `build/codegen.zig`:
   ```zig
   pub fn addCodegen(b: *std.Build, ..., opts: CodegenOptions) Codegen {
       const routes_mod = b.createModule(.{
           .root_source_file = b.path(opts.routes_src),
           ...
       });
       const mod = b.createModule(.{ .root_source_file = b.path("apps/codegen/src/codegen.zig"), ... });
       mod.addImport("routes", routes_mod);
       ...
   }
   ```
   `rootSourceFileFromOptions` only matches a `.root_source_file` field
   whose value is a literal path (`b.path("...")`, `.cwd_relative`
   literal, or an already-known pass-through helper) — `b.path(opts.routes_src)`
   is none of those, so `routes_mod` never binds, and `@import("routes")`
   inside `apps/codegen/src/codegen.zig` stays unresolved.

Measured impact (`zigroot --root apps/clusterd/src/main.zig --root
apps/iamd/src/main.zig --root apps/site-build/src/main.zig --root
apps/spa/src/main.zig --root apps/iam-cli/src/main.zig --root
apps/staticd/src/main.zig --root apps/cluster-cli/src/main.zig --root
apps/fuse-shim/src/main.zig --root apps/codegen/src/manifest_schema_gen.zig
--dir . --build-zig build.zig`, run from `backend/`): `@import("yaml")`
stays unresolved in all ~10 files under `libs/yaml/` and every consumer
that imports it (30 unresolved-import lines), and `@import("routes")` is
unresolved in `apps/codegen/src/codegen.zig` and its sub-modules (6
unresolved-import lines). As a direct consequence, real, used declarations
are misreported dead — e.g. `libs/http/route_schema.zig`'s
`SchemaResource` (+3 nested) is only reachable through the
`codegen.zig` → `@import("routes")` → `codegen_routes.zig` →
`route_schema.zig` chain, so it lands in the dead-declaration list even
though `codegen-dashboard`/`codegen-iam` genuinely depend on it.

Minimal repro:
```zig
// helper.zig
pub const Options = struct { dep: *std.Build.Module };
pub fn wire(b: *std.Build, opts: Options) void {
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig") });
    exe_mod.addImport("dep", opts.dep);
    _ = b.addExecutable(.{ .name = "app", .root_module = exe_mod });
}
```
```zig
// build.zig
const helper = @import("helper.zig");
pub fn build(b: *std.Build) void {
    const dep_mod = b.createModule(.{ .root_source_file = b.path("src/dep.zig") });
    helper.wire(b, .{ .dep = dep_mod });
}
```
`zigroot --root src/main.zig --dir . --build-zig build.zig` leaves
`src/main.zig: @import("dep")` unresolved even though `dep_mod` is a real,
unambiguous file created two lines above the call that forwards it.

Fix sketch: when `parseInto` scans a file and finds a `pub fn wire(b:
*std.Build, opts: <OptionsType>) ...` (or any function whose parameter is a
struct type declared in the same file) referencing `opts.<field>` as an
`addImport` module value or a `.root_source_file` path source, it needs a
second source of truth: every *call site* of that function elsewhere in
the scanned files, matched by callee (reusing `crossFileHelperCall`'s
`<alias>.<fn>` resolution), with the struct-literal argument's
`.<field> = <value>` bindings extracted the same way
`bindStructReturnFields` already extracts a returned struct's fields. Since
call sites are typically scanned in a different file (and possibly a
different pass) than the `Options` struct's consuming function, this
likely needs the same "index by file, resolve lazily" treatment
`Project.resolveViaBuildGraph`'s doc comment already flags issue 38's fix
as needing — a field named the same as the parameter (`opts`) inside a
`wire`-shaped function is a strong, low-false-positive signal to look for
this pattern, rather than trying to track arbitrary parameter dataflow in
general.
