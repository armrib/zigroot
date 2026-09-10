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

test "resolves a module published with b.addModule, with no further addImport/.imports wiring" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("storage", .{
        \\        .root_source_file = b.path("src/storage.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    _ = exe;
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("storage").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("src/storage.zig", paths[0]);
}

test "resolves a module published with b.addModule and wired into another module's inline .imports" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const compiler_mod = b.addModule("db_compiler", .{
        \\        .root_source_file = b.path("db-compiler/src/root.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("db-compiler/src/main.zig"),
        \\            .imports = &.{
        \\                .{ .name = "db_compiler", .module = compiler_mod },
        \\            },
        \\        }),
        \\    });
        \\    _ = exe;
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("db_compiler").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("db-compiler/src/root.zig", paths[0]);
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

test "resolves a module bound via an inline .imports field" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const myiam_mod = b.createModule(.{
        \\        .root_source_file = b.path("../../../sdks/iam/zig/iam-verify.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "chat",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .imports = &.{
        \\                .{ .name = "myiam-verify", .module = myiam_mod },
        \\            },
        \\        }),
        \\    });
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("myiam-verify").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("../../../sdks/iam/zig/iam-verify.zig", paths[0]);
}

test "resolves a module whose root_source_file goes through a b.path pass-through helper" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\fn srcPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        \\    return b.path(sub_path);
        \\}
        \\pub fn build(b: *std.Build) void {
        \\    const helper_mod = b.createModule(.{
        \\        .root_source_file = srcPath(b, "src/helper.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("helper", helper_mod);
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("helper").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("src/helper.zig", paths[0]);
}

test "resolves a module whose root_source_file goes through a b.path pass-through helper with a leading validation statement" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\fn srcPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        \\    b.build_root.handle.access(sub_path, .{}) catch |err| std.debug.panic(
        \\        "build.zig: root_source_file does not resolve: '{s}' ({s})",
        \\        .{ sub_path, @errorName(err) },
        \\    );
        \\    return b.path(sub_path);
        \\}
        \\pub fn build(b: *std.Build) void {
        \\    const helper_mod = b.createModule(.{
        \\        .root_source_file = srcPath(b, "src/helper.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("helper", helper_mod);
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("helper").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("src/helper.zig", paths[0]);
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

test "parseInto collects local-file @import specifiers, not package/module names" {
    var graph: BuildGraph = .empty;
    defer graph.deinit(t.allocator);

    var file_imports: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (file_imports.items) |p| t.allocator.free(p);
        file_imports.deinit(t.allocator);
    }

    try BuildGraph.parseInto(t.allocator, &graph,
        \\const std = @import("std");
        \\const helper = @import("build/helper.zig");
        \\const zlint = @import("zlint");
        \\pub fn build(b: *std.Build) void {
        \\    _ = helper;
        \\    _ = zlint;
        \\    _ = b;
        \\}
        \\
    , &file_imports);

    try t.expectEqual(@as(usize, 1), file_imports.items.len);
    try t.expectEqualStrings("build/helper.zig", file_imports.items[0]);
}

test "a local variable name reused across sibling blocks doesn't leak the shadowed binding" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    {
        \\        const m = b.createModule(.{ .root_source_file = b.path("tests/a_test.zig") });
        \\        _ = m;
        \\    }
        \\    {
        \\        const m = b.createModule(.{ .root_source_file = b.path("tests/b_test.zig") });
        \\        exe.root_module.addImport("b_test", m);
        \\    }
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("b_test").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("tests/b_test.zig", paths[0]);
}
