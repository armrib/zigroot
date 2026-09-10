# `pub const std_options` is reported as a dead declaration

```zig
// main.zig
const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main() !void {
    // ...
}
```

Running `zigroot --root main.zig --dir .` against a root file that declares
`std_options` reports it as dead:

```
dead declaration(s) (unreachable from any root):
  main.zig: std_options
```

`std_options` is never referenced by name anywhere in user code — like
`main`, it's a magic top-level declaration the Zig compiler itself looks
for and wires in (`std.options` resolves to the root source file's
`std_options` if present, falling back to `std.Options.default` otherwise;
see `lib/std/std.zig`'s `options` decl). A root file is free to declare it
with zero references and it's still very much alive.

Root cause: `Roots.build` (`src/Roots.zig:95-99`) only special-cases the
name `"main"` when scanning each root file's top-level symbols:

```zig
for (project.roots.items) |file_id| {
    const semantic = &project.file(file_id).semantic;
    if (semantic.symbols.getSymbolNamed("main")) |local| {
        try roots.add(gpa, .{ .file = file_id, .local = local }, .executable_entry);
    }
}
```

`std_options` (like `panic`, and pre-0.15 `os`) is a name Zig's compiler
recognizes structurally in a root source file, independent of `main`'s
presence — a library root (under `--library`) can have it too, and `pub`
already covers those under `--library`, but a non-`--library` executable
root's `std_options` has no `pub` requirement and isn't otherwise a root,
so it's flagged dead exactly as this repro shows.

Found running zigroot against formic's `spa` backend
(`backend/apps/spa/src/main.zig:148`):
`pub const std_options: std.Options = .{ .log_level = .info };`, with no
in-project reference to `std_options` anywhere — reported dead on every
run.

Fix sketch: in the same `for (project.roots.items)` loop that special-cases
`"main"`, also check for `"std_options"` (and, if in scope, `"panic"`) and
add each present one as a root the same way, alongside or replacing the
single `getSymbolNamed("main")` check with a small fixed list of
compiler-recognized top-level names to look up per root file.

Measured impact: `zigroot --root backend/apps/spa/src/main.zig --dir
backend --build-zig backend/build.zig` against formic's backend reports
`std_options` as a false-positive dead declaration on every run.
