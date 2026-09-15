//! Phase 37: classifying a dead symbol as test-support rather than dead.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");
const Roots = @import("Roots.zig");
const Resolver = @import("Resolver.zig");
const Reachability = @import("Reachability.zig");
const Report = @import("Report.zig");
const Scc = @import("Scc.zig");

fn writeFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(contents);
}

test "a helper only a test block reaches is test_only, not dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    _ = shipped(1);
        \\}
        \\
        \\fn shipped(n: u32) u32 {
        \\    return n + 1;
        \\}
        \\
        \\fn fixture() u32 {
        \\    return seed();
        \\}
        \\
        \\fn seed() u32 {
        \\    return 7;
        \\}
        \\
        \\fn reachedByNothing() u32 {
        \\    return 9;
        \\}
        \\
        \\test "shipped adds one" {
        \\    try std.testing.expectEqual(@as(u32, 8), shipped(fixture()));
        \\}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();
    _ = try project.addRoot(root_path);

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

    var test_roots = try Roots.buildTestBlockRoots(t.allocator, &project);
    defer test_roots.deinit(t.allocator);
    try test_roots.roots.appendSlice(t.allocator, roots.roots.items);
    var test_reachable = try Reachability.build(t.allocator, &project, &test_roots, &cross_file);
    defer test_reachable.deinit(t.allocator);

    var findings = try Report.collect(t.allocator, &project, dead.items, &scc, "", &test_reachable);
    defer Report.deinit(&findings, t.allocator);

    // `fixture` is named by the test block; `seed` only by `fixture`, so the
    // classification has to follow the chain, not just the direct reference.
    try t.expectEqual(Report.Class.test_only, classOf(findings.items, "fixture").?);
    try t.expectEqual(Report.Class.test_only, classOf(findings.items, "seed").?);
    try t.expectEqual(Report.Class.dead, classOf(findings.items, "reachedByNothing").?);
    try t.expectEqual(@as(?Report.Class, null), classOf(findings.items, "shipped"));
}

fn classOf(findings: []const Report.Finding, name: []const u8) ?Report.Class {
    for (findings) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.class;
    }
    return null;
}
