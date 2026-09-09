//! Phase 5: automatic root collection.

const std = @import("std");
const t = std.testing;
const Project = @import("../Project.zig");
const Roots = @import("Roots.zig");

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

    var roots = try Roots.build(t.allocator, &project);
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

    var roots = try Roots.build(t.allocator, &project);
    defer roots.deinit(t.allocator);

    const plugin_id = project.file(file_id).semantic.symbols.getSymbolNamed("plugin_init").?;

    try t.expectEqual(@as(usize, 1), roots.roots.items.len);
    try t.expect(roots.roots.items[0].symbol.eql(.{ .file = file_id, .local = plugin_id }));
    try t.expectEqual(Roots.RootKind.@"export", roots.roots.items[0].kind);
}
