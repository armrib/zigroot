//! Phase 10: Tarjan SCC over the declaration graph.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");
const Resolver = @import("Resolver.zig");
const Scc = @import("Scc.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

fn writeFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(contents);
}

test "a mutually-dead pair forms one cyclic component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn dead_a() void { dead_b(); }
        \\fn dead_b() void { dead_a(); }
        \\pub fn main() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var scc = try Scc.build(t.allocator, &project, &cross_file);
    defer scc.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const dead_a = semantic.symbols.getSymbolNamed("dead_a").?;
    const dead_b = semantic.symbols.getSymbolNamed("dead_b").?;
    const main = semantic.symbols.getSymbolNamed("main").?;

    const a_id: SymbolId = .{ .file = file_id, .local = dead_a };
    const b_id: SymbolId = .{ .file = file_id, .local = dead_b };
    const main_id: SymbolId = .{ .file = file_id, .local = main };

    const a_component = scc.componentOf(a_id).?;
    const b_component = scc.componentOf(b_id).?;
    try t.expectEqual(a_component, b_component);
    try t.expect(scc.isCyclic(a_component));
    try t.expectEqual(@as(usize, 2), scc.members(a_component).len);

    const main_component = scc.componentOf(main_id).?;
    try t.expect(main_component != a_component);
    try t.expect(!scc.isCyclic(main_component));
    try t.expectEqual(@as(usize, 1), scc.members(main_component).len);
}

test "direct recursion is a cyclic singleton component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn dead_recursive() void { dead_recursive(); }
        \\pub fn main() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var scc = try Scc.build(t.allocator, &project, &cross_file);
    defer scc.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const recursive = semantic.symbols.getSymbolNamed("dead_recursive").?;
    const id: SymbolId = .{ .file = file_id, .local = recursive };

    const component = scc.componentOf(id).?;
    try t.expectEqual(@as(usize, 1), scc.members(component).len);
    try t.expect(scc.isCyclic(component));
}

test "an anytype parameter never forms a self-edge cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\pub fn main() void { render(.{}); }
        \\fn render(args: anytype) void {
        \\    _ = args;
        \\    helper();
        \\}
        \\fn helper() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var scc = try Scc.build(t.allocator, &project, &cross_file);
    defer scc.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const args = semantic.symbols.getSymbolNamed("args").?;
    const id: SymbolId = .{ .file = file_id, .local = args };

    const component = scc.componentOf(id).?;
    try t.expectEqual(@as(usize, 1), scc.members(component).len);
    try t.expect(!scc.isCyclic(component));
}

test "a symbol with no edges is a non-cyclic singleton component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn dead_alone() void {}
        \\pub fn main() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var scc = try Scc.build(t.allocator, &project, &cross_file);
    defer scc.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const alone = semantic.symbols.getSymbolNamed("dead_alone").?;
    const id: SymbolId = .{ .file = file_id, .local = alone };

    const component = scc.componentOf(id).?;
    try t.expectEqual(@as(usize, 1), scc.members(component).len);
    try t.expect(!scc.isCyclic(component));
}
