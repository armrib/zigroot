# `b.path(...)` in a helper file `@import`ed into `build.zig` resolves against the wrong directory

```zig
// build.zig
const std = @import("std");
const helper = @import("build/helper.zig");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = helper.wire(b, b.standardTargetOptions(.{}), b.standardOptimizeOption(.{})),
    });
    b.installArtifact(exe);
}
```

```zig
// build/helper.zig
const std = @import("std");

pub fn wire(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("lib/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main.addImport("lib", lib_mod);
    return main;
}
```

With `src/main.zig` containing `@import("lib")`, running `--build-zig
build/helper.zig` (pointing at the file that actually contains the
`createModule`/`addImport` calls, since `build.zig` itself only holds an
`@import` and a function call) leaves `@import("lib")` unresolved and
`lib/mod.zig` reported as an orphan file, even though the module graph is
correctly wired.

Root cause: at runtime, `b.path("lib/mod.zig")` always resolves relative
to the build root — the directory of the top-level `build.zig` passed to
`zig build` — regardless of which file the `b.path(...)` call is lexically
written in. `Project.loadBuildGraph` (`src/Project.zig:56-67`) instead
takes `std.fs.path.dirname` of whatever file was passed via
`--build-zig` (`build_graph_dir`, `src/Project.zig:66`) and resolves every
`BuildGraph.resolve(...)` candidate against *that* directory
(`src/Project.zig:130`,
`std.fs.path.resolve(self.gpa, &.{ self.build_graph_dir, rel_path })`).
That's only correct when the scanned file *is* the build root; formic's
`backend/build.zig` instead stays a thin aggregator (per its own doc
comment: "the thin aggregator that creates cross-app steps ... and calls
in here") and delegates each app's actual module wiring to a per-app
`apps/<name>/build.zig` file, invoked as `<name>_build.wire(b, ...)` with
the aggregator's own `b`. Every `b.path("domains/...")` /
`b.path("platform/...")` call inside `apps/clusterd/build.zig` is relative
to `backend/` (the real build root), not `apps/clusterd/` — so pointing
`--build-zig` at `apps/clusterd/build.zig` (the only file that actually
has the `createModule`/`addImport` shapes `BuildGraph.parse` looks for)
resolves paths like `platform/uring/mod.zig` against
`apps/clusterd/platform/uring/mod.zig`, which doesn't exist. Every
locally-wired module in clusterd (`raft`, `edge`, `dns`, `pki`, `agent`,
`controlplane`, `volume`, `fuse`, `uring`, `nftables`, `wireguard`,
`string_pool`, `cpu`, `microarch`, `shutdown_signal`, `udp_send`,
`cluster_tuning`, `crypto_aead`, `route_schema`, `log_throttle`,
`iam_embrace_limits`, `file_wire`, `async_exec`, `iam_verify`, `yaml`, and
more) stays unresolved, and the entire `domains/`/`platform/`/`libs/` tree
it pulls in looks orphaned/dead.

Fix sketch: `BuildGraph` needs a way to know the real build root
independent of which file it's told to scan. Two ways to get there:
either (a) require `--build-zig` to always point at the actual top-level
build script and have `BuildGraph.parse` follow local
`@import("relative/file.zig")`s into sibling files, scanning each for
more `createModule`/`addModule`/`addImport` shapes while still resolving
every `b.path(...)` string against the *original* file's directory
(threading that base dir through the recursive scan instead of using each
sub-file's own directory); or (b) add a separate `--build-zig-root <dir>`
override so a directly-scanned helper file's `b.path(...)` calls resolve
against a caller-supplied root instead of `std.fs.path.dirname` of the
scanned file. (a) matches how `zig build` actually behaves and would also
pick up clusterd's module graph from a single `--build-zig backend/build.zig`
invocation, so it's the more faithful fix, but is a bigger change since
`BuildGraph.parse` currently only ever opens the one file
`Project.loadBuildGraph` reads (`src/Project.zig:56-63`).

Measured impact: running zigroot against formic's `clusterd` app
(`--root apps/clusterd/src/main.zig --dir backend --build-zig
apps/clusterd/build.zig`) reports 741 unresolved imports and the entire
`domains/`, `platform/`, `libs/` subtree (well over 100 files) as
orphaned/dead, none of which is real — it's all reachable through
`apps/clusterd/build.zig`'s module wiring once path resolution is fixed.
