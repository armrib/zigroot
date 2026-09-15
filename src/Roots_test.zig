//! Phase 5: automatic root collection.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");
const Roots = @import("Roots.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

fn writeFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(contents);
}

test "a root file's main becomes an executable_entry root" {
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

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    const main_id = project.file(file_id).semantic.symbols.getSymbolNamed("main").?;

    try t.expectEqual(@as(usize, 1), roots.roots.items.len);
    try t.expect(roots.roots.items[0].symbol.eql(.{ .file = file_id, .local = main_id }));
    try t.expectEqual(Roots.RootKind.executable_entry, roots.roots.items[0].kind);
}

test "a root file's std_options and panic become executable_entry roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const std = @import("std");
        \\pub const std_options: std.Options = .{ .log_level = .info };
        \\pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
        \\    _ = msg;
        \\    _ = trace;
        \\    _ = ret_addr;
        \\    unreachable;
        \\}
        \\pub fn main() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    const std_options_id: SymbolId = .{ .file = file_id, .local = project.file(file_id).semantic.symbols.getSymbolNamed("std_options").? };
    const panic_id: SymbolId = .{ .file = file_id, .local = project.file(file_id).semantic.symbols.getSymbolNamed("panic").? };

    for ([_]SymbolId{ std_options_id, panic_id }) |expected| {
        var found = false;
        for (roots.roots.items) |root| {
            if (root.symbol.eql(expected)) {
                try t.expectEqual(Roots.RootKind.executable_entry, root.kind);
                found = true;
            }
        }
        try t.expect(found);
    }
}

test "an export declaration is a root even with no references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "lib.zig",
        \\export fn plugin_init() void {}
        \\fn unused() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "lib.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    const plugin_id = project.file(file_id).semantic.symbols.getSymbolNamed("plugin_init").?;

    try t.expectEqual(@as(usize, 1), roots.roots.items.len);
    try t.expect(roots.roots.items[0].symbol.eql(.{ .file = file_id, .local = plugin_id }));
    try t.expectEqual(Roots.RootKind.@"export", roots.roots.items[0].kind);
}

test "a test block seeds no roots: test-only code is dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Widget = struct {
        \\    pub fn init() Widget { return .{}; }
        \\    pub fn run(self: Widget) void { _ = self; }
        \\};
        \\fn only_used_in_test() void {}
        \\pub fn main() void {}
        \\
        \\test "covers only_used_in_test" {
        \\    only_used_in_test();
        \\    var w: Widget = .init();
        \\    w.run();
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

    try t.expectEqual(@as(usize, 1), roots.roots.items.len);
    try t.expectEqualStrings("main", project.symbol(roots.roots.items[0].symbol).name);
}

test "pub symbols are only roots under PublicPolicy.root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "lib.zig",
        \\pub fn api() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "lib.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);
    const api_id: SymbolId = .{ .file = file_id, .local = project.file(file_id).semantic.symbols.getSymbolNamed("api").? };

    var analyze_roots = try Roots.build(t.allocator, &project, .analyze);
    defer analyze_roots.deinit(t.allocator);
    for (analyze_roots.roots.items) |root| try t.expect(!root.symbol.eql(api_id));

    var library_roots = try Roots.build(t.allocator, &project, .root);
    defer library_roots.deinit(t.allocator);

    var found = false;
    for (library_roots.roots.items) |root| {
        if (root.symbol.eql(api_id)) {
            try t.expectEqual(Roots.RootKind.public_api, root.kind);
            found = true;
        }
    }
    try t.expect(found);
}

test "only a top-level main is the entry point, not an earlier parameter or local named main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn helper(main: u32) u32 {
        \\    const panic = main;
        \\    return panic;
        \\}
        \\pub fn main() void {
        \\    _ = helper(1);
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

    try t.expectEqual(@as(usize, 1), roots.roots.items.len);
    const root_sym = project.symbol(roots.roots.items[0].symbol);
    try t.expectEqualStrings("main", root_sym.name);
    try t.expect(root_sym.flags.s_fn);
    try t.expectEqual(Roots.RootKind.executable_entry, roots.roots.items[0].kind);
}

test "a symbol referenced from a container-level comptime block is a comptime_block root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Registry = struct {
        \\    pub fn register() void {}
        \\};
        \\fn forced() void {}
        \\comptime {
        \\    _ = forced;
        \\    _ = Registry.register;
        \\}
        \\pub fn main() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const forced = semantic.symbols.getSymbolNamed("forced").?;
    const register = semantic.symbols.getSymbolNamed("register").?;

    var found_forced = false;
    var found_register = false;
    for (roots.roots.items) |root| {
        if (root.symbol.eql(.{ .file = file_id, .local = forced })) {
            try t.expectEqual(Roots.RootKind.comptime_block, root.kind);
            found_forced = true;
        }
        if (root.symbol.eql(.{ .file = file_id, .local = register })) {
            try t.expectEqual(Roots.RootKind.comptime_block, root.kind);
            found_register = true;
        }
    }
    try t.expect(found_forced);
    try t.expect(found_register);
}

test "a pub declaration in a file outside the project root is a public_api root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "proj/build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const sdk = b.createModule(.{
        \\        .root_source_file = b.path("../shared/sdk.zig"),
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
        \\    });
        \\    exe.root_module.addImport("sdk", sdk);
        \\}
        \\
    );
    try writeFile(tmp.dir, "proj/src/main.zig",
        \\const sdk = @import("sdk");
        \\pub fn main() void {
        \\    _ = sdk.verify();
        \\}
        \\
    );
    try writeFile(tmp.dir, "shared/sdk.zig",
        \\pub fn verify() u32 {
        \\    return 1;
        \\}
        \\pub fn usedOnlyByAnotherProject() u32 {
        \\    return 2;
        \\}
        \\fn privateHelper() u32 {
        \\    return 3;
        \\}
        \\
    );
    try writeFile(tmp.dir, "proj/src/local.zig",
        \\pub fn neverCalled() u32 {
        \\    return 4;
        \\}
        \\
    );

    const build_zig_path = try tmp.dir.realpathAlloc(t.allocator, "proj/build.zig");
    defer t.allocator.free(build_zig_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();
    try project.loadBuildGraph(build_zig_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    // The shared file's `pub` API is rooted; its private helper is not, and
    // neither is a `pub` declaration inside the project's own tree.
    var public_api_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer public_api_names.deinit(t.allocator);
    for (roots.roots.items) |root| {
        if (root.kind != .public_api) continue;
        // The file-root symbol carries no name and is `pub` in every file;
        // it stands for the container, not a declaration.
        const name = project.symbol(root.symbol).name;
        if (name.len == 0) continue;
        try public_api_names.append(t.allocator, name);
    }

    try t.expectEqual(@as(usize, 2), public_api_names.items.len);
    try t.expect(hasName(public_api_names.items, "verify"));
    try t.expect(hasName(public_api_names.items, "usedOnlyByAnotherProject"));
    try t.expect(!hasName(public_api_names.items, "privateHelper"));
    try t.expect(!hasName(public_api_names.items, "neverCalled"));
}

fn hasName(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}
