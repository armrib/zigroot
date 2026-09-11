//! Phase 1: project-wide file graph and orphan-file detection.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");

fn writeFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(contents);
}

test "follows @import chains and finds orphan files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src/main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    storage.start();
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/storage.zig",
        \\pub fn start() void {}
        \\
    );
    try writeFile(tmp.dir, "src/old_experiment.zig",
        \\pub fn unused() void {}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "src/main.zig");
    defer t.allocator.free(root_path);
    const dir_path = try tmp.dir.realpathAlloc(t.allocator, "src");
    defer t.allocator.free(dir_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    _ = try project.addRoot(root_path);
    try t.expectEqual(@as(usize, 2), project.files.items.len);

    var discovered = try project.discoverZigFiles(dir_path);
    defer {
        for (discovered.items) |p| t.allocator.free(p);
        discovered.deinit(t.allocator);
    }
    try t.expectEqual(@as(usize, 3), discovered.items.len);

    var orphans: usize = 0;
    var orphan_path: ?[]const u8 = null;
    for (discovered.items) |path| {
        if (!project.isReachable(path)) {
            orphans += 1;
            orphan_path = path;
        }
    }
    try t.expectEqual(@as(usize, 1), orphans);
    try t.expect(std.mem.endsWith(u8, orphan_path.?, "old_experiment.zig"));
}

test "Project.symbol resolves a SymbolId to its ZLint symbol" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\pub fn main() void {}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);
    const semantic = &project.file(file_id).semantic;
    const local_id = semantic.symbols.getSymbolNamed("main").?;

    const sym = project.symbol(.{ .file = file_id, .local = local_id });
    try t.expectEqualStrings("main", sym.name);
}

test "unresolved module imports are recorded, not treated as errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const std = @import("std");
        \\pub fn main() void {
        \\    _ = std;
        \\}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    _ = try project.addRoot(root_path);
    try t.expectEqual(@as(usize, 1), project.files.items.len);
    try t.expectEqual(@as(usize, 1), project.import_graph.unresolved.items.len);
    try t.expectEqualStrings("std", project.import_graph.unresolved.items[0].specifier);
}

test "loadBuildGraph resolves a named-module @import to its file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "build.zig",
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
    try writeFile(tmp.dir, "src/main.zig",
        \\const storage = @import("storage");
        \\pub fn main() void {
        \\    storage.start();
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/storage.zig",
        \\pub fn start() void {}
        \\
    );

    const build_zig_path = try tmp.dir.realpathAlloc(t.allocator, "build.zig");
    defer t.allocator.free(build_zig_path);
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "src/main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    try project.loadBuildGraph(build_zig_path);
    _ = try project.addRoot(root_path);

    try t.expectEqual(@as(usize, 2), project.files.items.len);
    try t.expectEqual(@as(usize, 0), project.import_graph.unresolved.items.len);
}

test "loadBuildGraph resolves a module returned by a cross-file helper call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "build.zig",
        \\const std = @import("std");
        \\const helper = @import("build/helper.zig");
        \\pub fn build(b: *std.Build) void {
        \\    const foo = helper.fooModule(b);
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("foo", foo);
        \\}
        \\
    );
    try writeFile(tmp.dir, "build/helper.zig",
        \\const std = @import("std");
        \\pub fn fooModule(b: *std.Build) *std.Build.Module {
        \\    return b.createModule(.{ .root_source_file = b.path("src/foo.zig") });
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/main.zig",
        \\const foo = @import("foo");
        \\pub fn main() void {
        \\    foo.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/foo.zig",
        \\pub fn run() void {}
        \\
    );

    const build_zig_path = try tmp.dir.realpathAlloc(t.allocator, "build.zig");
    defer t.allocator.free(build_zig_path);
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "src/main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    try project.loadBuildGraph(build_zig_path);
    _ = try project.addRoot(root_path);

    try t.expectEqual(@as(usize, 2), project.files.items.len);
    try t.expectEqual(@as(usize, 0), project.import_graph.unresolved.items.len);
}

test "loadBuildGraph loads a b.addTest root_module as a project root, not an orphan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    _ = exe;
        \\    const test_mod = b.createModule(.{
        \\        .root_source_file = b.path("src/tests/test_admin.zig"),
        \\    });
        \\    const t = b.addTest(.{ .root_module = test_mod });
        \\    _ = t;
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/main.zig",
        \\pub fn main() void {}
        \\
    );
    try writeFile(tmp.dir, "src/admin.zig",
        \\pub fn handle() void {}
        \\
    );
    try writeFile(tmp.dir, "src/tests/test_admin.zig",
        \\const admin = @import("../admin.zig");
        \\test "handle works" {
        \\    admin.handle();
        \\}
        \\
    );

    const build_zig_path = try tmp.dir.realpathAlloc(t.allocator, "build.zig");
    defer t.allocator.free(build_zig_path);
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "src/main.zig");
    defer t.allocator.free(root_path);
    const test_path = try tmp.dir.realpathAlloc(t.allocator, "src/tests/test_admin.zig");
    defer t.allocator.free(test_path);
    const admin_path = try tmp.dir.realpathAlloc(t.allocator, "src/admin.zig");
    defer t.allocator.free(admin_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    try project.loadBuildGraph(build_zig_path);
    _ = try project.addRoot(root_path);

    try t.expect(project.isReachable(test_path));
    try t.expect(project.isReachable(admin_path));
}

test "loadBuildGraph follows a split-out helper file's b.path() calls relative to the build root, not the helper's own directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "build.zig",
        \\const std = @import("std");
        \\const helper = @import("build/helper.zig");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = helper.wire(b, b.standardTargetOptions(.{}), b.standardOptimizeOption(.{})),
        \\    });
        \\    b.installArtifact(exe);
        \\}
        \\
    );
    try writeFile(tmp.dir, "build/helper.zig",
        \\const std = @import("std");
        \\
        \\pub fn wire(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        \\    const lib_mod = b.createModule(.{
        \\        .root_source_file = b.path("lib/mod.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    const main = b.createModule(.{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    main.addImport("lib", lib_mod);
        \\    return main;
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/main.zig",
        \\const lib = @import("lib");
        \\pub fn main() void {
        \\    lib.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "lib/mod.zig",
        \\pub fn run() void {}
        \\
    );

    const build_zig_path = try tmp.dir.realpathAlloc(t.allocator, "build.zig");
    defer t.allocator.free(build_zig_path);
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "src/main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    try project.loadBuildGraph(build_zig_path);
    _ = try project.addRoot(root_path);

    try t.expectEqual(@as(usize, 2), project.files.items.len);
    try t.expectEqual(@as(usize, 0), project.import_graph.unresolved.items.len);
}

test "loadBuildGraph resolves a module forwarded through an Options-struct field into a helper's wire() call (issue 39)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "build.zig",
        \\const std = @import("std");
        \\const helper = @import("helper.zig");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const dep_mod = b.createModule(.{ .root_source_file = b.path("src/dep.zig") });
        \\    helper.wire(b, .{ .dep = dep_mod });
        \\}
        \\
    );
    try writeFile(tmp.dir, "helper.zig",
        \\const std = @import("std");
        \\
        \\pub const Options = struct { dep: *std.Build.Module };
        \\
        \\pub fn wire(b: *std.Build, opts: Options) void {
        \\    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig") });
        \\    exe_mod.addImport("dep", opts.dep);
        \\    _ = b.addExecutable(.{ .name = "app", .root_module = exe_mod });
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/main.zig",
        \\const dep = @import("dep");
        \\pub fn main() void {
        \\    dep.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "src/dep.zig",
        \\pub fn run() void {}
        \\
    );

    const build_zig_path = try tmp.dir.realpathAlloc(t.allocator, "build.zig");
    defer t.allocator.free(build_zig_path);
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "src/main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    try project.loadBuildGraph(build_zig_path);
    _ = try project.addRoot(root_path);

    try t.expectEqual(@as(usize, 2), project.files.items.len);
    try t.expectEqual(@as(usize, 0), project.import_graph.unresolved.items.len);
}

test "a .zig-suffixed named-module import consults build_graph instead of only guessing a sibling path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const handlers_mod = b.createModule(.{
        \\        .root_source_file = b.path("domains/fuse/handlers.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("apps/fuse-shim/src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("handlers.zig", handlers_mod);
        \\}
        \\
    );
    try writeFile(tmp.dir, "apps/fuse-shim/src/main.zig",
        \\const handlers = @import("handlers.zig");
        \\pub fn main() void {
        \\    handlers.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "domains/fuse/handlers.zig",
        \\pub fn run() void {}
        \\
    );

    const build_zig_path = try tmp.dir.realpathAlloc(t.allocator, "build.zig");
    defer t.allocator.free(build_zig_path);
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "apps/fuse-shim/src/main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    try project.loadBuildGraph(build_zig_path);
    _ = try project.addRoot(root_path);

    try t.expectEqual(@as(usize, 2), project.files.items.len);
    try t.expectEqual(@as(usize, 0), project.import_graph.unresolved.items.len);
}
