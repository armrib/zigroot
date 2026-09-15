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

const SymbolId = @import("SymbolId.zig").SymbolId;

/// The kind of the edge to `to` among `targets`, if there is one. With
/// several (a `.definite` hop and a `.possible` re-derivation of the same
/// target), the most confident wins.
fn edgeTo(targets: []const SymbolGraph.Target, to: SymbolId) ?SymbolGraph.EdgeKind {
    var best: ?SymbolGraph.EdgeKind = null;
    for (targets) |target| {
        if (!target.to.eql(to)) continue;
        if (best == null or @intFromEnum(target.kind) < @intFromEnum(best.?)) best = target.kind;
    }
    return best;
}

/// Every edge among `targets` that isn't to the file root (an `@import`
/// binding's alias target, edged alongside whatever it was used to reach).
fn nonRootEdgeCount(targets: []const SymbolGraph.Target) usize {
    var n: usize = 0;
    for (targets) |target| {
        if (@intFromEnum(target.to.local) != 0) n += 1;
    }
    return n;
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
    try t.expectEqual(@as(usize, 1), nonRootEdgeCount(outgoing));
    try t.expectEqual(SymbolGraph.EdgeKind.definite, edgeTo(outgoing, .{ .file = storage_id, .local = start_sym }).?);
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
    const inner_sym = project.file(storage_id).semantic.symbols.getSymbolNamed("Inner").?;

    const outgoing = cross_file.outgoing(.{ .file = main_id, .local = main_sym });
    try t.expectEqual(SymbolGraph.EdgeKind.definite, edgeTo(outgoing, .{ .file = storage_id, .local = run_sym }).?);
    // The container hopped through is as used as the member reached.
    try t.expect(edgeTo(outgoing, .{ .file = storage_id, .local = inner_sym }) != null);
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

test "allocator.create(T) resolves T from the call's argument, not a return-type annotation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const std = @import("std");
        \\const foo = @import("foo.zig");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    const allocator = gpa.allocator();
        \\    const server = try allocator.create(foo.Foo);
        \\    server.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "foo.zig",
        \\pub const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\    pub fn unused(self: *Foo) void { _ = self; }
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

    const foo_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "foo.zig")) break f.id;
    } else unreachable;
    const foo_semantic = &project.file(foo_id).semantic;
    const run_sym = foo_semantic.symbols.getSymbolNamed("run").?;
    const unused_sym = foo_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = foo_id, .local = run_sym }));
    try t.expect(!reachability.isReachable(.{ .file = foo_id, .local = unused_sym }));
}

test "a for-loop payload over a call-init variable chains an instance method" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const entry_mod = @import("entry.zig");
        \\
        \\fn tailOf(buf: []entry_mod.Entry, n: usize) []entry_mod.Entry {
        \\    return buf[0..n];
        \\}
        \\
        \\pub fn main() void {
        \\    var buf: [4]entry_mod.Entry = undefined;
        \\    const tail = tailOf(buf[0..], 2);
        \\    for (tail) |*e| {
        \\        _ = e.payload();
        \\    }
        \\}
        \\
    );
    try writeFile(tmp.dir, "entry.zig",
        \\pub const Entry = struct {
        \\    v: u32 = 0,
        \\    pub fn payload(self: *const Entry) u32 { return self.v; }
        \\    pub fn unused(self: *const Entry) u32 { return self.v; }
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

    const entry_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "entry.zig")) break f.id;
    } else unreachable;
    const entry_semantic = &project.file(entry_id).semantic;
    const payload_sym = entry_semantic.symbols.getSymbolNamed("payload").?;
    const unused_sym = entry_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = entry_id, .local = payload_sym }));
    try t.expect(!reachability.isReachable(.{ .file = entry_id, .local = unused_sym }));
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

test "a catch-wrapped call initializer chains an instance method the same as try" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    const w = storage.Widget.make(1) catch return;
        \\    w.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub const Widget = struct {
        \\    pub fn make(id: u8) !Widget { _ = id; return .{}; }
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

test "an orelse-wrapped call initializer to an optional-returning function chains an instance method" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const storage = @import("storage.zig");
        \\pub fn main() void {
        \\    const w = storage.Widget.find(1) orelse return;
        \\    w.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "storage.zig",
        \\pub const Widget = struct {
        \\    pub fn find(id: u8) ?Widget { _ = id; return .{}; }
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
    try t.expectEqual(SymbolGraph.EdgeKind.possible, edgeTo(outgoing, .{ .file = storage_id, .local = run_sym }).?);
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
    try t.expectEqual(@as(usize, 2), nonRootEdgeCount(outgoing));
    try t.expectEqual(SymbolGraph.EdgeKind.unknown, edgeTo(outgoing, .{ .file = storage_id, .local = start_sym }).?);
    try t.expectEqual(SymbolGraph.EdgeKind.unknown, edgeTo(outgoing, .{ .file = storage_id, .local = stop_sym }).?);
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

test "const Schema = @import(\"json.zig\").Schema narrows the binding to that export, not the file root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Schema = @import("json.zig").Schema;
        \\pub fn main() !Schema {
        \\    var ctx: Schema.Context = .{};
        \\    return Schema{ .int = ctx.dummy() };
        \\}
        \\
    );
    try writeFile(tmp.dir, "json.zig",
        \\pub const Schema = union(enum) {
        \\    int: i32,
        \\
        \\    pub const Context = struct {
        \\        pub fn dummy(self: *Context) i32 {
        \\            _ = self;
        \\            return 0;
        \\        }
        \\    };
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

    const json_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "json.zig")) break f.id;
    } else unreachable;
    const json_semantic = &project.file(json_id).semantic;
    const schema_sym = json_semantic.symbols.getSymbolNamed("Schema").?;
    const context_sym = json_semantic.symbols.getSymbolNamed("Context").?;
    const dummy_sym = json_semantic.symbols.getSymbolNamed("dummy").?;

    try t.expect(reachability.isReachable(.{ .file = json_id, .local = schema_sym }));
    try t.expect(reachability.isReachable(.{ .file = json_id, .local = context_sym }));
    try t.expect(reachability.isReachable(.{ .file = json_id, .local = dummy_sym }));
}

test "an instance method reached through a cross-file-typed struct field is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The `state.meta.is_member(...)` shape: `meta`'s type is declared in
    // another file, and the call is two field hops away from `state`.
    try writeFile(tmp.dir, "main.zig",
        \\const ms = @import("meta_state.zig");
        \\pub const State = struct {
        \\    meta: ms.MetaState,
        \\};
        \\pub fn main() void {
        \\    var state: State = undefined;
        \\    state.meta.is_member();
        \\}
        \\
    );
    try writeFile(tmp.dir, "meta_state.zig",
        \\pub const MetaState = struct {
        \\    pub fn is_member(self: *MetaState) void { _ = self; }
        \\    pub fn unused(self: *MetaState) void { _ = self; }
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

    const meta_state_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "meta_state.zig")) break f.id;
    } else unreachable;
    const meta_state_semantic = &project.file(meta_state_id).semantic;
    const is_member_sym = meta_state_semantic.symbols.getSymbolNamed("is_member").?;
    const unused_sym = meta_state_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = meta_state_id, .local = is_member_sym }));
    try t.expect(!reachability.isReachable(.{ .file = meta_state_id, .local = unused_sym }));
}

test "an instance method reached through an array-index into a cross-file-typed slice field is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Issue 11: `self.conns[idx].reset()` — `conns`'s element type crosses
    // an `@import` boundary, so the array-index hop needs the same
    // stuck/resume redirect the plain field-access hop already gets.
    try writeFile(tmp.dir, "main.zig",
        \\const conn_mod = @import("conn.zig");
        \\pub const State = struct {
        \\    conns: []conn_mod.Conn,
        \\
        \\    pub fn free_conn(self: *State, idx: u16) void {
        \\        self.conns[idx].reset();
        \\    }
        \\};
        \\pub fn main() void {
        \\    var state: State = undefined;
        \\    state.free_conn(0);
        \\}
        \\
    );
    try writeFile(tmp.dir, "conn.zig",
        \\pub const Conn = struct {
        \\    pub fn reset(self: *Conn) void { _ = self; }
        \\    pub fn unused(self: *Conn) void { _ = self; }
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

    const conn_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "conn.zig")) break f.id;
    } else unreachable;
    const conn_semantic = &project.file(conn_id).semantic;
    const reset_sym = conn_semantic.symbols.getSymbolNamed("reset").?;
    const unused_sym = conn_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = conn_id, .local = reset_sym }));
    try t.expect(!reachability.isReachable(.{ .file = conn_id, .local = unused_sym }));
}

test "a field access isn't shadowed by a same-named local in another method of the container" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Issue 13: `init`'s local named `conns` (same name as the `conns`
    // field) used to win `findExport`'s `exports` lookup before `members`
    // was ever checked, stranding `.reset()` reached only through the real
    // field.
    try writeFile(tmp.dir, "main.zig",
        \\const conn_mod = @import("conn.zig");
        \\const std = @import("std");
        \\pub const State = struct {
        \\    conns: []conn_mod.Conn,
        \\
        \\    pub fn init(allocator: std.mem.Allocator) !State {
        \\        const conns = try allocator.alloc(conn_mod.Conn, 4);
        \\        for (conns) |*c| c.* = .{};
        \\        return .{ .conns = conns };
        \\    }
        \\
        \\    pub fn free_conn(self: *State, idx: u16) void {
        \\        self.conns[idx].reset();
        \\    }
        \\};
        \\pub fn main() void {
        \\    var state = State.init(std.heap.page_allocator) catch unreachable;
        \\    state.free_conn(0);
        \\}
        \\
    );
    try writeFile(tmp.dir, "conn.zig",
        \\pub const Conn = struct {
        \\    pub fn reset(self: *Conn) void { _ = self; }
        \\    pub fn unused(self: *Conn) void { _ = self; }
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

    const conn_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "conn.zig")) break f.id;
    } else unreachable;
    const conn_semantic = &project.file(conn_id).semantic;
    const reset_sym = conn_semantic.symbols.getSymbolNamed("reset").?;
    const unused_sym = conn_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = conn_id, .local = reset_sym }));
    try t.expect(!reachability.isReachable(.{ .file = conn_id, .local = unused_sym }));
}

test "a call-init chained through a cross-file-typed struct field's instance method is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The issue-10 shape: `state.table.get()`'s callee is itself an
    // instance-field chain (`table`'s type crosses an `@import` boundary),
    // and `get`'s own return type is a pointer to a further cross-file type.
    try writeFile(tmp.dir, "main.zig",
        \\const t = @import("table.zig");
        \\pub const State = struct {
        \\    table: t.Table,
        \\};
        \\pub fn main() void {
        \\    var state: State = undefined;
        \\    const inner = state.table.get() catch return;
        \\    inner.used_only_via_chain();
        \\}
        \\
    );
    try writeFile(tmp.dir, "table.zig",
        \\const i = @import("inner.zig");
        \\pub const Table = struct {
        \\    pub fn get(self: *Table) !*i.Inner { _ = self; unreachable; }
        \\};
        \\
    );
    try writeFile(tmp.dir, "inner.zig",
        \\pub const Inner = struct {
        \\    pub fn used_only_via_chain(self: *Inner) void { _ = self; }
        \\    pub fn unused(self: *Inner) void { _ = self; }
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

    const inner_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "inner.zig")) break f.id;
    } else unreachable;
    const inner_semantic = &project.file(inner_id).semantic;
    const used_sym = inner_semantic.symbols.getSymbolNamed("used_only_via_chain").?;
    const unused_sym = inner_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = inner_id, .local = used_sym }));
    try t.expect(!reachability.isReachable(.{ .file = inner_id, .local = unused_sym }));
}

test "a call chained directly off another call, with a cross-file return type, is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Issue 16: `cast(raw).putImpl()` — no intermediate variable to hang
    // `cast`'s resolved return type on, and that return type itself crosses
    // an `@import` boundary.
    try writeFile(tmp.dir, "main.zig",
        \\const target = @import("target.zig");
        \\fn cast(raw: *anyopaque) *target.HttpClient {
        \\    return @ptrCast(@alignCast(raw));
        \\}
        \\fn put(raw: *anyopaque) void {
        \\    cast(raw).putImpl();
        \\}
        \\pub fn main() void {
        \\    put(undefined);
        \\}
        \\
    );
    try writeFile(tmp.dir, "target.zig",
        \\pub const HttpClient = struct {
        \\    pub fn putImpl(self: *HttpClient) void { _ = self; }
        \\    pub fn unused(self: *HttpClient) void { _ = self; }
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

    const target_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "target.zig")) break f.id;
    } else unreachable;
    const target_semantic = &project.file(target_id).semantic;
    const put_impl_sym = target_semantic.symbols.getSymbolNamed("putImpl").?;
    const unused_sym = target_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = target_id, .local = put_impl_sym }));
    try t.expect(!reachability.isReachable(.{ .file = target_id, .local = unused_sym }));
}

test "an instance method reached through an if-payload capture of a cross-file-typed optional field is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The issue-01 shape: `log`'s type is never spelled out, it's the
    // unwrapped payload of `self.meta_log`'s own declared type
    // (`?ml.MetaLog`), bound by an `if (...) |*log|` capture.
    try writeFile(tmp.dir, "main.zig",
        \\const ml = @import("meta_log.zig");
        \\pub const State = struct {
        \\    meta_log: ?ml.MetaLog,
        \\    pub fn meta_append(self: *State) void {
        \\        if (self.meta_log) |*log| log.append();
        \\    }
        \\};
        \\pub fn main() void {
        \\    var state: State = undefined;
        \\    state.meta_append();
        \\}
        \\
    );
    try writeFile(tmp.dir, "meta_log.zig",
        \\pub const MetaLog = struct {
        \\    pub fn append(self: *MetaLog) void { _ = self; }
        \\    pub fn unused(self: *MetaLog) void { _ = self; }
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

    const meta_log_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "meta_log.zig")) break f.id;
    } else unreachable;
    const meta_log_semantic = &project.file(meta_log_id).semantic;
    const append_sym = meta_log_semantic.symbols.getSymbolNamed("append").?;
    const unused_sym = meta_log_semantic.symbols.getSymbolNamed("unused").?;

    try t.expect(reachability.isReachable(.{ .file = meta_log_id, .local = append_sym }));
    try t.expect(!reachability.isReachable(.{ .file = meta_log_id, .local = unused_sym }));
}

test "an alias of a re-exported @import (const Project = lib.Project) resolves instance calls and decl literals through it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const lib = @import("lib.zig");
        \\const Project = lib.Project;
        \\pub fn main() void {
        \\    var project: Project = .init(1);
        \\    defer project.deinit();
        \\    project.load();
        \\}
        \\
    );
    try writeFile(tmp.dir, "lib.zig",
        \\pub const Project = @import("Project.zig");
        \\pub const Unused = @import("Unused.zig");
        \\
    );
    try writeFile(tmp.dir, "Project.zig",
        \\const Project = @This();
        \\n: u32,
        \\pub fn init(n: u32) Project { return .{ .n = n }; }
        \\pub fn deinit(self: *Project) void { _ = self; }
        \\pub fn load(self: *Project) void { _ = self; }
        \\pub fn unused(self: *Project) void { _ = self; }
        \\
    );
    try writeFile(tmp.dir, "Unused.zig",
        \\pub fn never() void {}
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    var found_unused = false;
    var found_never = false;
    for (dead.items) |d| {
        const name = project.symbol(d.id).name;
        if (std.mem.eql(u8, name, "unused")) found_unused = true;
        if (std.mem.eql(u8, name, "never")) found_never = true;
        try t.expect(!std.mem.eql(u8, name, "init"));
        try t.expect(!std.mem.eql(u8, name, "deinit"));
        try t.expect(!std.mem.eql(u8, name, "load"));
        try t.expect(!std.mem.eql(u8, name, "Project"));
    }
    try t.expect(found_unused);
    try t.expect(found_never);
}

test "a parameter typed as an @import binding (file-as-struct) chains method calls into that file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Project = @import("Project.zig");
        \\fn work(project: *const Project) void {
        \\    project.run();
        \\}
        \\pub fn main() void {
        \\    var p: Project = .{};
        \\    work(&p);
        \\}
        \\
    );
    try writeFile(tmp.dir, "Project.zig",
        \\const Project = @This();
        \\n: u32 = 0,
        \\pub fn run(self: *const Project) void { _ = self; }
        \\pub fn idle(self: *const Project) void { _ = self; }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("idle", project.symbol(dead.items[0].id).name);
}

test "a variable initialized from a call-and-field chain across files takes the declared type of what the chain lands on" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Project = @import("Project.zig");
        \\fn work(project: *const Project) void {
        \\    const semantic = &project.file(0).semantic;
        \\    semantic.getBinding("x");
        \\    const name = project.symbol(0).name;
        \\    _ = name;
        \\}
        \\pub fn main() void {
        \\    var p: Project = .{};
        \\    work(&p);
        \\}
        \\
    );
    try writeFile(tmp.dir, "Project.zig",
        \\const Project = @This();
        \\const File = @import("File.zig");
        \\const Semantic = @import("Semantic.zig");
        \\files: [1]File = undefined,
        \\pub fn file(self: *const Project, i: usize) *const File { return &self.files[i]; }
        \\pub fn symbol(self: *const Project, i: usize) *const Semantic.Symbol { _ = self; _ = i; return undefined; }
        \\
    );
    try writeFile(tmp.dir, "File.zig",
        \\const Semantic = @import("Semantic.zig");
        \\semantic: Semantic,
        \\
    );
    try writeFile(tmp.dir, "Semantic.zig",
        \\pub const Symbol = @import("Symbol.zig");
        \\pub fn getBinding(self: *const @This(), name: []const u8) void { _ = self; _ = name; }
        \\pub fn resolveBinding(self: *const @This()) void { _ = self; }
        \\
    );
    try writeFile(tmp.dir, "Symbol.zig",
        \\name: []const u8,
        \\pub fn unusedMethod(self: *const @This()) void { _ = self; }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(t.allocator);
    for (dead.items) |d| try names.append(t.allocator, project.symbol(d.id).name);

    try t.expectEqual(@as(usize, 2), names.items.len);
    for (names.items) |name| {
        try t.expect(std.mem.eql(u8, name, "resolveBinding") or std.mem.eql(u8, name, "unusedMethod"));
    }
}

test "a field typed through an alias of an import's export (owner: []Symbol.Id.Optional) chains method calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Semantic = @import("Semantic.zig");
        \\const Symbol = Semantic.Symbol;
        \\const Map = struct {
        \\    owner: []Symbol.Id.Optional,
        \\    pub fn get(self: *const Map, i: usize) ?u32 {
        \\        return self.owner[i].unwrap();
        \\    }
        \\};
        \\pub fn main() void {
        \\    var m: Map = .{ .owner = &.{} };
        \\    _ = m.get(0);
        \\}
        \\
    );
    try writeFile(tmp.dir, "Semantic.zig",
        \\pub const Symbol = @import("Symbol.zig");
        \\
    );
    try writeFile(tmp.dir, "Symbol.zig",
        \\pub const Id = struct {
        \\    pub const Optional = enum(u32) {
        \\        none = 0,
        \\        _,
        \\        pub fn unwrap(self: Optional) ?u32 { return if (self == .none) null else @intFromEnum(self); }
        \\        pub fn other(self: Optional) void { _ = self; }
        \\    };
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("other", project.symbol(dead.items[0].id).name);
}

test "a bare use of a value alias reaches what it names, and an intermediate hop is reached too" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const util = @import("util.zig");
        \\const NominalId = util.NominalId;
        \\const Id = NominalId(u32);
        \\const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub fn run() void {}
        \\    };
        \\};
        \\pub fn main() void {
        \\    var id: Id = .{ .raw = 1 };
        \\    _ = &id;
        \\    Outer.Inner.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "util.zig",
        \\pub fn NominalId(comptime T: type) type {
        \\    return struct { raw: T };
        \\}
        \\pub fn Unused(comptime T: type) type {
        \\    return struct { raw: T };
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
    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);
    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("Unused", project.symbol(dead.items[0].id).name);
}

test "an instance method reached through &self.slice[i] on a cross-file element type is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const engine = @import("engine.zig");
        \\pub fn main() void {
        \\    var e: engine.Engine = undefined;
        \\    _ = e.run(0);
        \\}
        \\
    );
    try writeFile(tmp.dir, "engine.zig",
        \\const http = @import("http.zig");
        \\pub const Engine = struct {
        \\    parsers: []http.Parser,
        \\    pub fn run(self: *Engine, id: usize) u32 {
        \\        var parser = &self.parsers[id];
        \\        return parser.feed();
        \\    }
        \\};
        \\
    );
    try writeFile(tmp.dir, "http.zig",
        \\pub const Parser = struct {
        \\    state: u32 = 0,
        \\    pub fn feed(self: *Parser) u32 { return self.state; }
        \\    pub fn unusedOne(self: *Parser) u32 { return self.state; }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}

test "an instance method reached through an .? unwrap of a cross-file-typed optional field is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const engine = @import("engine.zig");
        \\pub fn main() void {
        \\    var e: engine.Engine = undefined;
        \\    _ = e.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "engine.zig",
        \\const http = @import("http.zig");
        \\pub const Engine = struct {
        \\    parser: ?*http.Parser = null,
        \\    pub fn run(self: *Engine) u32 {
        \\        return self.parser.?.feed();
        \\    }
        \\};
        \\
    );
    try writeFile(tmp.dir, "http.zig",
        \\pub const Parser = struct {
        \\    state: u32 = 0,
        \\    pub fn feed(self: *Parser) u32 { return self.state; }
        \\    pub fn unusedOne(self: *Parser) u32 { return self.state; }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}

test "a member reached through an inline @import(...).member expression is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\pub fn main() void {
        \\    _ = dispatch;
        \\}
        \\const dispatch = [_]*const fn () u32{
        \\    @import("handlers.zig").services_handler.collect,
        \\};
        \\
    );
    try writeFile(tmp.dir, "handlers.zig",
        \\pub const services_handler = struct {
        \\    pub fn collect() u32 { return 1; }
        \\    pub fn unusedOne() u32 { return 2; }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}

test "an optional-payload method call resolves when the struct is declared in another file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const loop = @import("loop.zig");
        \\const spoa = @import("spoa.zig");
        \\
        \\pub const Server = struct {
        \\    spoa: ?*spoa.SpoaServer = null,
        \\
        \\    pub const run = loop.run;
        \\};
        \\
        \\pub fn main() void {
        \\    var s = Server{};
        \\    s.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "loop.zig",
        \\const Server = @import("main.zig").Server;
        \\
        \\pub fn run(self: *Server) void {
        \\    if (self.spoa) |sp| sp.onAccept(1);
        \\}
        \\
    );
    try writeFile(tmp.dir, "spoa.zig",
        \\pub const SpoaServer = struct {
        \\    n: u32 = 0,
        \\    pub fn onAccept(self: *SpoaServer, res: i32) void {
        \\        self.n +%= @intCast(res);
        \\    }
        \\    pub fn unusedOne(self: *SpoaServer) void {
        \\        self.n = 0;
        \\    }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}

test "a for-payload method call resolves when the struct is declared in another file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const loop = @import("loop.zig");
        \\const conn = @import("conn.zig");
        \\
        \\pub const Server = struct {
        \\    conns: []conn.Conn = &.{},
        \\
        \\    pub const run = loop.run;
        \\};
        \\
        \\pub fn main() void {
        \\    var s = Server{};
        \\    s.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "loop.zig",
        \\const Server = @import("main.zig").Server;
        \\
        \\pub fn run(self: *Server) void {
        \\    for (self.conns) |c| c.close();
        \\}
        \\
    );
    try writeFile(tmp.dir, "conn.zig",
        \\pub const Conn = struct {
        \\    fd: i32 = -1,
        \\    pub fn close(self: Conn) void {
        \\        _ = self;
        \\    }
        \\    pub fn unusedOne(self: Conn) void {
        \\        _ = self;
        \\    }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}

test "a member of an inline anonymous struct literal is not reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\pub fn main() void {
        \\    apply(struct {
        \\        fn lessThan(a: u32, b: u32) bool {
        \\            return a < b;
        \\        }
        \\    }.lessThan);
        \\}
        \\
        \\fn apply(f: *const fn (u32, u32) bool) void {
        \\    _ = f(1, 2);
        \\}
        \\
        \\fn unusedOne() void {}
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}

test "an &container.array[i] element method resolves when the struct is declared in another file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const loop = @import("loop.zig");
        \\const dispatch = @import("dispatch.zig");
        \\
        \\pub fn main() void {
        \\    var state = loop.State{};
        \\    dispatch.run(&state);
        \\}
        \\
    );
    try writeFile(tmp.dir, "loop.zig",
        \\pub const Conn = struct {
        \\    n: u32 = 0,
        \\    pub fn allocInflight(self: *Conn, tag: u32) void {
        \\        self.n = tag;
        \\    }
        \\    pub fn unusedOne(self: *Conn) void {
        \\        self.n = 0;
        \\    }
        \\};
        \\
        \\pub const State = struct {
        \\    conns: [4]Conn = .{.{}} ** 4,
        \\};
        \\
    );
    try writeFile(tmp.dir, "dispatch.zig",
        \\const loop = @import("loop.zig");
        \\
        \\pub fn run(state: *loop.State) void {
        \\    const c = &state.conns[0];
        \\    c.allocInflight(7);
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
    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);
    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}

test "a member of an anonymous struct return type resolves across a file boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const pool_mod = @import("pool.zig");
        \\
        \\const Holder = struct {
        \\    pool: pool_mod.Pool = .{},
        \\    pub fn run(self: *Holder) void {
        \\        const acquired = self.pool.acquire() orelse return;
        \\        acquired.worker.stage();
        \\    }
        \\};
        \\
        \\pub fn main() void {
        \\    var h: Holder = .{};
        \\    h.run();
        \\}
        \\
    );
    try writeFile(tmp.dir, "pool.zig",
        \\pub const Worker = struct {
        \\    n: u32 = 0,
        \\    pub fn stage(self: *Worker) void {
        \\        self.n += 1;
        \\    }
        \\    pub fn unusedOne(self: *Worker) void {
        \\        self.n += 2;
        \\    }
        \\};
        \\
        \\pub const Pool = struct {
        \\    workers: [2]Worker = .{ .{}, .{} },
        \\    pub fn acquire(self: *Pool) ?struct { id: u16, worker: *Worker } {
        \\        return .{ .id = 0, .worker = &self.workers[0] };
        \\    }
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), dead.items.len);
    try t.expectEqualStrings("unusedOne", project.symbol(dead.items[0].id).name);
}
