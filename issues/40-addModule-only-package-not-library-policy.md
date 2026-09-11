# A `build.zig` that only calls `b.addModule` (no `addExecutable`/`addLibrary`) doesn't get library `PublicPolicy`, so its whole public API is misreported dead

`main.zig` picks `PublicPolicy.root` (every `pub` symbol is an automatic
root) only `if (bg.has_library and !bg.has_executable)`
(`src/main.zig:45-47`), and `has_library` is set only by `BuildGraph`'s
`addLibrary` case (`src/BuildGraph.zig:278-280`). A `build.zig` that
exposes a package purely via `b.addModule("name", .{ .root_source_file =
... })` — the standard Zig package-manager convention for a library with
no compiled artifact of its own — never sets `has_library`, so it falls
back to `PublicPolicy.analyze`. With no `addExecutable`/`addLibrary` at
all, `Roots.build`'s only other root sources (`main`/`std_options`/
`panic`, `export`s, `test`-block references) are also empty, so the
module's entire `pub` surface — its actual, real API — is reported as
100% dead code.

Reproduced against `formic/backend/libs/serdez`, whose `build.zig` is:
```zig
pub fn build(b: *std.Build) void {
    ...
    _ = b.addModule("serdez", .{
        .root_source_file = b.path("src/Serializer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/Serializer.zig"),
        ...
    });
    const unit_tests = b.addTest(.{ .test_runner = test_runner, .root_module = test_module });
    ...
}
```
No `addExecutable`/`addLibrary` anywhere. Running `zigroot` from
`backend/libs/serdez/`:
```
loaded 1 file(s) reachable from 1 root(s)

4 dead declaration(s) (unreachable from any root):
  src/Serializer.zig: writeTagged (+7 nested)
  cycle of 1 declaration(s), unreachable from any root:
    src/Serializer.zig: serializedSize
  src/Serializer.zig: uleb128Size (+3 nested)
  src/Serializer.zig: addressSize (+1 nested)
```
Every one of those is a real `pub fn` — `serdez`'s actual public API,
consumed by `backend/domains/raft/{LogRing,Io,RaftState}.zig` via
`@import("serdez")` elsewhere in the wider `backend/` project — reported
dead solely because this package's own `build.zig`, scanned standalone,
has no `addExecutable`/`addLibrary` to flip `has_library`. (The single
"root" the run does find is `src/Serializer.zig` itself, reached only
because `addModule`'s and the test's `root_module` both happen to point at
the same file — the file is *reachable*, but none of its declarations are,
since nothing roots them.)

Fix sketch: treat a `build.zig` with an `addModule`/`addModule`-name
export and no `addExecutable`/`addLibrary` the same as a library for
`PublicPolicy` purposes — i.e. widen `BuildGraph.has_library`'s condition
at `src/BuildGraph.zig:291` (`addModule` case) to also set
`has_library = true`, or have `main.zig`'s policy check also read whether
any named module was exported at all (`BuildGraph.resolve` already tracks
these by name). The `addExecutable`/`addLibrary`-only check conflates "no
compiled artifact defined" with "not a library," which is wrong for any
package that's purely a source module for other projects to import via
`b.dependency(...).module("name")` — a common enough Zig package shape
(`serdez` here is one real instance) that this can't be dismissed as an
edge case.
