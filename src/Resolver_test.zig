//! Phase 6: cross-file `Symbol -> Symbol` edges through `@import`.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");
const FileId = @import("FileId.zig").FileId;
const Roots = @import("Roots.zig");
const Reachability = @import("Reachability.zig");
const Resolver = @import("Resolver.zig");
const SymbolGraph = @import("SymbolGraph.zig");

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
    try t.expect(outgoing[0].to.eql(.{ .file = storage_id, .local = start_sym }));
}

test "storage.Inner.run() chains a cross-file edge through a nested container" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    storage.Inner.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub const Inner = struct {
        \\    pub fn run() void {}
        \\};
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
    const run_sym = project.file(storage_id).semantic.symbols.getSymbolNamed("run").?;

    const outgoing = cross_file.outgoing(.{ .file = main_id, .local = main_sym });
    try t.expectEqual(@as(usize, 1), outgoing.len);
    try t.expect(outgoing[0].to.eql(.{ .file = storage_id, .local = run_sym }));
}

test "s.run() on a cross-file-typed variable produces a cross-file .possible edge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
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

    const main_id = try project.addRoot(root_path);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    const main_semantic = &project.file(main_id).semantic;
    const main_sym = main_semantic.symbols.getSymbolNamed("main").?;

    const storage_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "storage.zig")) break f.id;
    } else unreachable;
    const run_sym = project.file(storage_id).semantic.symbols.getSymbolNamed("run").?;

    const outgoing = cross_file.outgoing(.{ .file = main_id, .local = main_sym });
    var found: ?SymbolGraph.Target = null;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = storage_id, .local = run_sym })) found = edge;
    }
    try t.expect(found != null);
    try t.expectEqual(SymbolGraph.EdgeKind.possible, found.?.kind);
}

test "a symbol only reachable via a cross-file-typed variable's instance method is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    var s: storage.Widget = undefined;
        \\    s.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub const Widget = struct {
        \\    pub fn run(self: *Widget) void { _ = self; }
        \\    pub fn unused(self: *Widget) void { _ = self; }
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const storage_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "storage.zig")) break f.id;
    } else unreachable;
    const storage_semantic = &project.file(storage_id).semantic;
    const run_sym = storage_semantic.symbols.getSymbolNamed("run").?;
    const unused_sym = storage_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = storage_id, .local = run_sym }));
    try t.expect(!reachability.isReachable(.{ .file = storage_id, .local = unused_sym }));
}

test "a symbol only reachable via a generic type-returning function's init is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const walk = @import("walk.zig");
        \\pub fn main() void {
        \\    const LintWalker = walk.Walker(u8);
        \\    var w = LintWalker.init();
        \\    _ = &w;
        \\}
        \\
    );
    try writeFile(tmp.dir, "walk.zig",
        \\pub fn Walker(comptime T: type) type {
        \\    return struct {
        \\        pub fn init() @This() {
        \\            used();
        \\            return .{};
        \\        }
        \\    };
        \\}
        \\fn used() void {}
        \\fn unused() void {}
        \\
    );

    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    _ = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const walk_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "walk.zig")) break f.id;
    } else unreachable;
    const walk_semantic = &project.file(walk_id).semantic;
    const init_sym = walk_semantic.symbols.getSymbolNamed("init").?;
    const used_sym = walk_semantic.symbols.getSymbolNamed("used").?;
    const unused_sym = walk_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = walk_id, .local = init_sym }));
    try t.expect(reachability.isReachable(.{ .file = walk_id, .local = used_sym }));
    try t.expect(!reachability.isReachable(.{ .file = walk_id, .local = unused_sym }));
}

test "@field(storage, \"start\") produces a cross-file .possible edge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    @field(storage, "start")();
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
    try t.expect(outgoing[0].to.eql(.{ .file = storage_id, .local = start_sym }));
    try t.expectEqual(SymbolGraph.EdgeKind.possible, outgoing[0].kind);
}

test "@field(storage, \"Inner\").run() chains a cross-file @field hop into a further .field hop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    @field(storage, "Inner").run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub const Inner = struct {
        \\    pub fn run() void {}
        \\};
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
    const run_sym = project.file(storage_id).semantic.symbols.getSymbolNamed("run").?;

    const outgoing = cross_file.outgoing(.{ .file = main_id, .local = main_sym });
    try t.expectEqual(@as(usize, 1), outgoing.len);
    try t.expect(outgoing[0].to.eql(.{ .file = storage_id, .local = run_sym }));
    try t.expectEqual(SymbolGraph.EdgeKind.possible, outgoing[0].kind);
}

test "@field(storage, name) with a runtime name produces cross-file .unknown edges to every export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main(name: []const u8) void {
        \\    @field(storage, name)();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub fn start() void {}
        \\pub fn stop() void {}
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
    const stop_sym = project.file(storage_id).semantic.symbols.getSymbolNamed("stop").?;

    const outgoing = cross_file.outgoing(.{ .file = main_id, .local = main_sym });
    try t.expectEqual(@as(usize, 2), outgoing.len);
    for (outgoing) |target| try t.expectEqual(SymbolGraph.EdgeKind.unknown, target.kind);
    try t.expect(outgoing[0].to.eql(.{ .file = storage_id, .local = start_sym }) or outgoing[0].to.eql(.{ .file = storage_id, .local = stop_sym }));
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

    var roots = try Roots.build(t.allocator, &project, .analyze);
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
