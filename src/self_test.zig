//! Runs the analysis on this repository's own `build.zig` and checks the
//! findings against the expected list — the integration test the rest of
//! the suite's synthetic fixtures can't replace.
//!
//! Expected findings, and why each is genuinely unreachable from the CLI:
//! - `root.zig`'s re-exports the CLI never uses: `zigroot_mod` is the
//!   library the executable is built on, but `build.zig` declares no
//!   library artifact, so executable policy applies and a `pub` re-export
//!   nothing in `main.zig` names is dead as far as the binary goes.
//! - Everything under `src/semantic/`: upstream ZLint API the analyzer
//!   doesn't call (`Reference.Flags` helpers, `Span` arithmetic, JSON
//!   formatters, ...) or only its own tests do. Kept as copied so diffs
//!   against upstream stay readable, so only the *set of files* is pinned
//!   here, not every name.
//!
//! Skipped when the test binary isn't run from the repository root (no
//! `build.zig` in the cwd), which is where `zig build test` runs it.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");
const Roots = @import("Roots.zig");
const Resolver = @import("Resolver.zig");
const Reachability = @import("Reachability.zig");
const Scc = @import("Scc.zig");
const Report = @import("Report.zig");

const expected_project_layer = [_][]const u8{
    "src/root.zig:FileId",
    "src/root.zig:File",
    "src/root.zig:ImportGraph",
    "src/root.zig:OwnerMap",
    "src/root.zig:SymbolGraph",
    "src/root.zig:SymbolId",
    "src/root.zig:DynamicField",
    "src/root.zig:DeclLiteral",
    "src/root.zig:InstanceType",
    "src/root.zig:BuildGraph",
    "src/root.zig:ZonFile",
};

test "self-run: analyzing this repository reports only the expected dead declarations" {
    std.fs.cwd().access("build.zig", .{}) catch return error.SkipZigTest;
    std.fs.cwd().access("src/root.zig", .{}) catch return error.SkipZigTest;

    var project: Project = .init(t.allocator);
    defer project.deinit();
    try project.loadBuildGraph("build.zig");

    try t.expectEqual(@as(usize, 0), project.errorCount());
    try t.expect(project.roots.items.len >= 1);

    // Every discovered file is analyzed, a build script, or test-only:
    // nothing is orphaned.
    var discovered = try project.discoverZigFiles(".");
    defer {
        for (discovered.items) |p| t.allocator.free(p);
        discovered.deinit(t.allocator);
    }
    var test_only: usize = 0;
    for (discovered.items) |path| {
        if (project.isReachable(path)) continue;
        if (!project.isTestOnly(path)) {
            std.debug.print("unexpected orphan: {s}\n", .{path});
            return error.TestUnexpectedResult;
        }
        test_only += 1;
    }
    try t.expect(test_only > 0);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);
    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);
    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);
    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);
    var scc = try Scc.build(t.allocator, &project, &cross_file);
    defer scc.deinit(t.allocator);

    var findings = try Report.collect(t.allocator, &project, dead.items, &scc, project.build_graph_dir);
    defer Report.deinit(&findings, t.allocator);

    var seen = [_]bool{false} ** expected_project_layer.len;
    var failed = false;
    for (findings.items) |f| {
        if (f.possible) {
            std.debug.print("unexpected possibly-dead finding: {s}:{d}:{d}: {s} {s}\n", .{ f.path, f.line, f.column, f.kind, f.name });
            failed = true;
            continue;
        }
        if (std.mem.startsWith(u8, f.path, "src/semantic/")) continue;

        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ f.path, f.name }) catch continue;
        const idx = for (expected_project_layer, 0..) |expected, i| {
            if (std.mem.eql(u8, expected, key)) break i;
        } else {
            std.debug.print("unexpected dead declaration: {s}:{d}:{d}: {s} {s}\n", .{ f.path, f.line, f.column, f.kind, f.name });
            failed = true;
            continue;
        };
        seen[idx] = true;
    }
    for (expected_project_layer, seen) |expected, was_seen| {
        if (!was_seen) {
            std.debug.print("expected dead declaration no longer reported: {s}\n", .{expected});
            failed = true;
        }
    }
    try t.expect(!failed);
}
