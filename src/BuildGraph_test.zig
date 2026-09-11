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

test "resolves a module bound with addAnonymousImport, whose module and options are inline" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const bench_mod = b.createModule(.{ .root_source_file = b.path("src/bench_runner.zig") });
        \\    bench_mod.addAnonymousImport("bench.zig", .{ .root_source_file = b.path("apps/site-build/src/bench.zig") });
        \\    const exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
        \\    _ = exe;
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("bench.zig").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("apps/site-build/src/bench.zig", paths[0]);
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

test "resolves a module whose root_source_file is a direct .cwd_relative LazyPath literal" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const foo = b.createModule(.{
        \\        .root_source_file = .{ .cwd_relative = "../shared/foo.zig" },
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("foo", foo);
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("foo").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("../shared/foo.zig", paths[0]);
}

test "resolves a module whose root_source_file is .{ .cwd_relative = b.pathFromRoot(...) }" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const foo = b.createModule(.{
        \\        .root_source_file = .{ .cwd_relative = b.pathFromRoot("../shared/foo.zig") },
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("foo", foo);
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("foo").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("../shared/foo.zig", paths[0]);
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
    , &file_imports, null);

    try t.expectEqual(@as(usize, 1), file_imports.items.len);
    try t.expectEqualStrings("build/helper.zig", file_imports.items[0]);
}

test "rootSourceFileOfHelperFn resolves a helper fn whose body returns b.createModule(...)" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\pub fn fooModule(b: *std.Build) *std.Build.Module {
        \\    return b.createModule(.{ .root_source_file = b.path("src/foo.zig") });
        \\}
        \\
    ;
    var tree = try std.zig.Ast.parse(t.allocator, source, .zig);
    defer tree.deinit(t.allocator);

    var call_buf: [1]std.zig.Ast.Node.Index = undefined;
    var struct_buf: [2]std.zig.Ast.Node.Index = undefined;
    const tok = BuildGraph.rootSourceFileOfHelperFn(&tree, "fooModule", &call_buf, &struct_buf).?;

    const path = try BuildGraph.parseStringLiteral(t.allocator, &tree, tok);
    defer t.allocator.free(path);
    try t.expectEqualStrings("src/foo.zig", path);
}

test "parseInto resolves a call to a cross-file-import-aliased helper via the given resolver" {
    const StubResolver = struct {
        fn resolve(context: *anyopaque, gpa: std.mem.Allocator, rel_import_path: []const u8, fn_name: []const u8) !?[]u8 {
            _ = context;
            try t.expectEqualStrings("build/vendor.zig", rel_import_path);
            try t.expectEqualStrings("yamlModule", fn_name);
            return try gpa.dupe(u8, "libs/yaml/yaml.zig");
        }
    };
    var dummy_ctx: u8 = 0;
    const resolver: BuildGraph.HelperResolver = .{ .context = &dummy_ctx, .resolveFn = StubResolver.resolve };

    var graph: BuildGraph = .empty;
    defer graph.deinit(t.allocator);

    var file_imports: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (file_imports.items) |p| t.allocator.free(p);
        file_imports.deinit(t.allocator);
    }

    try BuildGraph.parseInto(t.allocator, &graph,
        \\const std = @import("std");
        \\const vendor = @import("build/vendor.zig");
        \\pub fn build(b: *std.Build) void {
        \\    const yaml_mod = vendor.yamlModule(b);
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("yaml", yaml_mod);
        \\}
        \\
    , &file_imports, resolver);

    const paths = graph.resolve("yaml").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("libs/yaml/yaml.zig", paths[0]);
}

test "records a b.addTest root_module bound to a local createModule variable as a test root" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const test_mod = b.createModule(.{
        \\        .root_source_file = b.path("src/tests/test_admin.zig"),
        \\    });
        \\    const t = b.addTest(.{ .root_module = test_mod });
        \\    _ = t;
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), graph.test_roots.items.len);
    try t.expectEqualStrings("src/tests/test_admin.zig", graph.test_roots.items[0]);
}

test "records a b.addTest with an inline root_module createModule as a test root" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const t = b.addTest(.{
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/tests/test_http.zig") }),
        \\    });
        \\    _ = t;
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), graph.test_roots.items.len);
    try t.expectEqualStrings("src/tests/test_http.zig", graph.test_roots.items[0]);
}

test "records a b.addTest using the older root_source_file shape as a test root" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const t = b.addTest(.{ .root_source_file = b.path("src/tests/test_path.zig") });
        \\    _ = t;
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), graph.test_roots.items.len);
    try t.expectEqualStrings("src/tests/test_path.zig", graph.test_roots.items[0]);
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

test "resolves an addImport value that's a field access into a helper's returned modules struct" {
    var graph = try BuildGraph.parse(t.allocator,
        \\const std = @import("std");
        \\const Mods = struct { foo: *std.Build.Module };
        \\
        \\fn wireModules(b: *std.Build) Mods {
        \\    const foo = b.createModule(.{ .root_source_file = b.path("src/foo.zig") });
        \\    return .{ .foo = foo };
        \\}
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const mods = wireModules(b);
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("foo", mods.foo);
        \\}
        \\
    );
    defer graph.deinit(t.allocator);

    const paths = graph.resolve("foo").?;
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("src/foo.zig", paths[0]);
}
