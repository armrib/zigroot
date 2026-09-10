//! Phase 11: build.zig module graph extraction.

const std = @import("std");
const t = std.testing;
const BuildGraph = @import("BuildGraph.zig");

test "resolves a locally-created module bound with addImport" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const storage_mod = b.createModule(.{
        \\        .root_source_file = b.path("src/storage.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("storage", storage_mod);
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("storage").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("src/storage.zig", paths[0]);
}

test "a module sourced from a dependency stays unresolved" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const dep = b.dependency("zlint", .{});
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("zlint", dep.module("zlint"));
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    try t.expectEqual(@as(?[]const []const u8, null), graph.resolve("zlint"));
}

test "an addImport of an unrelated identifier is ignored, not crashing" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("target_ish", target);
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    try t.expectEqual(@as(usize, 0), graph.modules.count());
}

test "an import name addImport'd once per OS branch keeps every candidate" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const linux_mod = b.createModule(.{
        \\        .root_source_file = b.path("src/linux.zig"),
        \\    });
        \\    const windows_mod = b.createModule(.{
        \\        .root_source_file = b.path("src/windows.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    const target = b.standardTargetOptions(.{});
        \\    if (target.result.os.tag == .linux) {
        \\        exe.root_module.addImport("platform", linux_mod);
        \\    } else {
        \\        exe.root_module.addImport("platform", windows_mod);
        \\    }
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("platform").?;
    try t.expectEqual(@as(usize, 2), paths.len);
    try t.expectEqualStrings("src/linux.zig", paths[0]);
    try t.expectEqualStrings("src/windows.zig", paths[1]);
}
