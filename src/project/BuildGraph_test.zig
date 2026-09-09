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

    try t.expectEqualStrings("src/storage.zig", graph.resolve("storage").?);
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

    try t.expectEqual(@as(?[]const u8, null), graph.resolve("zlint"));
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
