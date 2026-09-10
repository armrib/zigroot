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

test "a symbol referenced only from a test block is a test root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn only_used_in_test() void {}
        \\pub fn main() void {}
        \\
        \\test "covers only_used_in_test" {
        \\    only_used_in_test();
        \\}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    const target_id = project.file(file_id).semantic.symbols.getSymbolNamed("only_used_in_test").?;

    var found = false;
    for (roots.roots.items) |root| {
        if (root.symbol.eql(.{ .file = file_id, .local = target_id })) {
            try t.expectEqual(Roots.RootKind.@"test", root.kind);
            found = true;
        }
    }
    try t.expect(found);
}

test "an instance-method call on a locally-typed variable in a test block is a test root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\pub fn main() void {}
        \\
        \\test "covers Foo.run" {
        \\    var s: Foo = undefined;
        \\    s.run();
        \\}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    const run_id = project.file(file_id).semantic.symbols.getSymbolNamed("run").?;

    var found = false;
    for (roots.roots.items) |root| {
        if (root.symbol.eql(.{ .file = file_id, .local = run_id })) {
            try t.expectEqual(Roots.RootKind.@"test", root.kind);
            found = true;
        }
    }
    try t.expect(found);
}

test "an instance-method call on a cross-file-typed variable in a test block is a test root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {}
        \\
        \\test "covers Widget.run" {
        \\    var s: storage.Widget = undefined;
        \\    s.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub const Widget = struct {
        \\    pub fn run(self: *Widget) void { _ = self; }
        \\};
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    _ = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    const storage_id = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "storage.zig")) break f.id;
    } else unreachable;
    const run_id = project.file(storage_id).semantic.symbols.getSymbolNamed("run").?;

    var found = false;
    for (roots.roots.items) |root| {
        if (root.symbol.eql(.{ .file = storage_id, .local = run_id })) {
            try t.expectEqual(Roots.RootKind.@"test", root.kind);
            found = true;
        }
    }
    try t.expect(found);
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
