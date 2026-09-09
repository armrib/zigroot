//! Phase 5: BFS reachability from `Roots` over `SymbolGraph`.

const std = @import("std");
const t = std.testing;
const Project = @import("../Project.zig");
const Roots = @import("Roots.zig");
const Reachability = @import("Reachability.zig");
const Resolver = @import("Resolver.zig");

fn writeFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(contents);
}

test "declarations only referenced by other dead code are reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn dead_a() void { dead_b(); }
        \\fn dead_b() void {}
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const dead_a = semantic.symbols.getSymbolNamed("dead_a").?;
    const dead_b = semantic.symbols.getSymbolNamed("dead_b").?;
    const main = semantic.symbols.getSymbolNamed("main").?;

    try t.expect(reachability.isReachable(.{ .file = file_id, .local = main }));
    try t.expect(!reachability.isReachable(.{ .file = file_id, .local = dead_a }));
    try t.expect(!reachability.isReachable(.{ .file = file_id, .local = dead_b }));

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    var found_a = false;
    var found_b = false;
    for (dead.items) |id| {
        if (id.eql(.{ .file = file_id, .local = dead_a })) found_a = true;
        if (id.eql(.{ .file = file_id, .local = dead_b })) found_b = true;
        try t.expect(!id.eql(.{ .file = file_id, .local = main }));
    }
    try t.expect(found_a);
    try t.expect(found_b);
}

test "a call chain reachable from main is not dead, even transitively" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn c() void {}
        \\fn b() void { c(); }
        \\fn a() void { b(); }
        \\pub fn main() void { a(); }
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project);
    defer roots.deinit(t.allocator);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    inline for (.{ "a", "b", "c", "main" }) |name| {
        const id = semantic.symbols.getSymbolNamed(name).?;
        try t.expect(reachability.isReachable(.{ .file = file_id, .local = id }));
    }
}

test "export declarations are reachable even without any referencing root" {
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const plugin_init = semantic.symbols.getSymbolNamed("plugin_init").?;
    const unused = semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = file_id, .local = plugin_init }));
    try t.expect(!reachability.isReachable(.{ .file = file_id, .local = unused }));
}
