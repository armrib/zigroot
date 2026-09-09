//! Phase 6: cross-file `Symbol -> Symbol` edges through `@import`.

const std = @import("std");
const t = std.testing;
const Project = @import("../Project.zig");
const FileId = @import("FileId.zig").FileId;
const Roots = @import("Roots.zig");
const Reachability = @import("Reachability.zig");
const Resolver = @import("Resolver.zig");

fn writeFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(contents);
}

test "storage.start() produces a cross-file edge to storage.zig's start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    storage.start();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub fn start() void {}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const main_id = try project.addRoot(root_path);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    const main_semantic = &project.file(main_id).semantic;
    const main_sym = main_semantic.symbols.getSymbolNamed("main").?;

    const storage_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "storage.zig")) break f.id;
    } else unreachable;
    const start_sym = project.file(storage_id).semantic.symbols.getSymbolNamed("start").?;

    const outgoing = cross_file.outgoing(.{ .file = main_id, .local = main_sym });
    try t.expectEqual(@as(usize, 1), outgoing.len);
    try t.expect(outgoing[0].eql(.{ .file = storage_id, .local = start_sym }));
}

test "a symbol only reachable across an @import is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    storage.start();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub fn start() void {}
        \\fn unused() void {}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    _ = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project);
    defer roots.deinit(t.allocator);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const storage_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "storage.zig")) break f.id;
    } else unreachable;
    const storage_semantic = &project.file(storage_id).semantic;
    const start_sym = storage_semantic.symbols.getSymbolNamed("start").?;
    const unused_sym = storage_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = storage_id, .local = start_sym }));
    try t.expect(!reachability.isReachable(.{ .file = storage_id, .local = unused_sym }));
}
