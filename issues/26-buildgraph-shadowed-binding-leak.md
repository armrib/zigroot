# A `build.zig` that reuses a local variable name across sibling blocks leaks memory in `BuildGraph.parseInto`

```zig
pub fn build(b: *std.Build) void {
    // ...
    {
        const m = b.createModule(.{ .root_source_file = b.path("tests/a_test.zig") });
        m.addImport("main", main);
        // ... b.addTest(.{ .root_module = m, ... })
    }
    {
        const m = b.createModule(.{ .root_source_file = b.path("tests/b_test.zig") });
        m.addImport("agent", domains_agent);
        // ... b.addTest(.{ .root_module = m, ... })
    }
    // ... repeated for every test file, each in its own `{ ... }` block
}
```

Running `zigroot --build-zig build.zig ...` against a `build.zig` shaped like
this reports `error(gpa): memory address ... leaked` for every reused
binding beyond the first, and exits non-zero — even though the file parses
fine and every module is wired correctly.

Found running zigroot against formic's clusterd backend: its `build.zig`
wires ~27 separate per-test modules, each declared as `const m =
b.createModule(.{ ... })` inside its own `{ ... }` block (one block per
`b.addTest`, so `m` only needs to be valid within that block). 15 leak
reports came out of one run.

Root cause: `BuildGraph.parseInto`'s AST walk (`src/BuildGraph.zig:105-179`)
is flat — it iterates every node in the file by index and has no concept of
block scope. `bindings` (`src/BuildGraph.zig:99`,
`std.StringHashMapUnmanaged([]const u8)`) is keyed purely by variable name,
so when a second `const m = ...` is seen, `bindings.put(gpa, var_name,
path)` (`src/BuildGraph.zig:117`, `:125`) silently overwrites the previous
`m` entry — even though the two `m`s are in disjoint blocks and never alias
at runtime. The previous entry's `path` (heap-allocated by
`parseStringLiteral`) is never freed: it's neither reachable through the
hashmap anymore nor copied into `result` (it's only copied into `result` if
some `addImport`/`.imports` call later resolves it via `pathForBinding`,
which for these test-only modules never happens — `m` itself is never
looked up as an import *target*, only used to build `b.addTest`). The
cleanup loop at the end of `parseInto` (`src/BuildGraph.zig:183-184`) only
sees whatever is left in the map, i.e. one entry per unique name, so every
shadowed-and-overwritten `path` before that is unreachable and leaks.

This is a resource leak, not a resolution-correctness bug — the shadowed
bindings here are never resolution targets anyway, so `BuildGraph`'s
output isn't wrong, just leaky. Under `GeneralPurposeAllocator`'s leak
detection (as `main.zig` uses) this trips leak reports and a non-zero exit
on every run against a `build.zig` with this (common — repeated per-test
`{ const m = ...; ... }` blocks) shape, independent of any real orphan/dead
findings.

Fix sketch: before overwriting an existing `bindings` entry in the three
`bindings.put` call sites (`src/BuildGraph.zig:117`, `:125`, and the
`addModule` case around `:151-159` feeds `result` directly rather than
`bindings` so it's unaffected), free the old value if the key is already
present — e.g. switch to `getOrPutValue`-style logic: `const gop = try
bindings.getOrPut(gpa, var_name); if (gop.found_existing) gpa.free(gop.value_ptr.*); gop.value_ptr.* = path;`
instead of a bare `.put`.

Measured impact: `zigroot --root backend/apps/clusterd/src/main.zig --dir
backend --build-zig backend/apps/clusterd/build.zig` against formic's
backend exits non-zero purely from `error(gpa): memory address ... leaked`
noise (15 leaks in one run), on top of / independent from whatever real
orphan/dead findings the run also reports.
