//! Phase 5: BFS reachability from `Roots` over `SymbolGraph`.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");
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

    var roots = try Roots.build(t.allocator, &project, .analyze);
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
    for (dead.items) |d| {
        if (d.id.eql(.{ .file = file_id, .local = dead_a })) found_a = true;
        if (d.id.eql(.{ .file = file_id, .local = dead_b })) found_b = true;
        try t.expect(!d.id.eql(.{ .file = file_id, .local = main }));
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

    var roots = try Roots.build(t.allocator, &project, .analyze);
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

    var roots = try Roots.build(t.allocator, &project, .analyze);
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

test "extern declarations are never reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\extern fn c_helper() void;
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const c_helper = semantic.symbols.getSymbolNamed("c_helper").?;
    for (dead.items) |d| {
        try t.expect(!d.id.eql(.{ .file = file_id, .local = c_helper }));
    }
}

test "a symbol only referenced from a test block is not reported dead" {
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const target = semantic.symbols.getSymbolNamed("only_used_in_test").?;
    try t.expect(reachability.isReachable(.{ .file = file_id, .local = target }));
}

test "a symbol only reached via @field(Foo, name) is possibly, not definitely, reachable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Foo = struct {
        \\    pub fn bar() void {}
        \\};
        \\pub fn main() void {
        \\    const name = getName();
        \\    @field(Foo, name)();
        \\}
        \\fn getName() []const u8 { return "bar"; }
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const file_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const bar = semantic.symbols.getSymbolNamed("bar").?;

    try t.expect(!reachability.isReachable(.{ .file = file_id, .local = bar }));
    try t.expect(reachability.isPossiblyReachable(.{ .file = file_id, .local = bar }));

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    var found_possible_bar = false;
    for (dead.items) |d| {
        if (d.id.eql(.{ .file = file_id, .local = bar })) {
            try t.expect(d.possible);
            found_possible_bar = true;
        }
    }
    try t.expect(found_possible_bar);
}

test "@field(Foo, \"bar\") with a comptime-known name is definitely reachable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Foo = struct {
        \\    pub fn bar() void {}
        \\};
        \\pub fn main() void {
        \\    @field(Foo, "bar")();
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const bar = semantic.symbols.getSymbolNamed("bar").?;
    try t.expect(reachability.isReachable(.{ .file = file_id, .local = bar }));
}
