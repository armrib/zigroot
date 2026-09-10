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
