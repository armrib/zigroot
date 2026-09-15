//! Phase 5: BFS reachability from `Roots` over `SymbolGraph`.

const std = @import("std");
const t = std.testing;
const Project = @import("Project.zig");
const Roots = @import("Roots.zig");
const Reachability = @import("Reachability.zig");
const Resolver = @import("Resolver.zig");
const FileId = @import("FileId.zig").FileId;

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

test "everything called from a function with an anytype parameter stays reachable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const helper = @import("helper.zig");
        \\pub fn main() void { render("x", .{}); }
        \\pub fn render(p: []const u8, args: anytype) void {
        \\    local_helper();
        \\    helper.format_it(p, args);
        \\}
        \\fn local_helper() void {}
        \\
    );
    try writeFile(tmp.dir, "helper.zig",
        \\pub fn format_it(p: []const u8, args: anytype) void {
        \\    _ = p;
        \\    _ = args;
        \\    deep();
        \\}
        \\fn deep() void {}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const main_id = try project.addRoot(root_path);
    const helper_id: FileId = for (project.files.items) |f| {
        if (std.mem.endsWith(u8, f.path, "helper.zig")) break f.id;
    } else unreachable;

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const main_sem = &project.file(main_id).semantic;
    inline for (.{ "helper", "p", "args", "local_helper" }) |name| {
        const id = main_sem.symbols.getSymbolNamed(name).?;
        try t.expect(reachability.isReachable(.{ .file = main_id, .local = id }));
    }
    const helper_sem = &project.file(helper_id).semantic;
    inline for (.{ "format_it", "deep" }) |name| {
        const id = helper_sem.symbols.getSymbolNamed(name).?;
        try t.expect(reachability.isReachable(.{ .file = helper_id, .local = id }));
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

test "a catch |_| discard capture is never reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn mayFail() !void {
        \\    return error.Oops;
        \\}
        \\
        \\pub fn main() !void {
        \\    mayFail() catch |_| {};
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

    for (dead.items) |d| {
        const sym = project.file(d.id.file).semantic.symbols.get(d.id.local);
        try t.expect(!std.mem.eql(u8, sym.name, "_"));
    }
}

test "locals and parameters of a dead function roll up into one finding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn dead_fn(x: i32, y: i32) void {
        \\    const total = x + y;
        \\    _ = total;
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const dead_fn = semantic.symbols.getSymbolNamed("dead_fn").?;
    const x = semantic.symbols.getSymbolNamed("x").?;
    const y = semantic.symbols.getSymbolNamed("y").?;
    const total = semantic.symbols.getSymbolNamed("total").?;

    var found_parent: ?usize = null;
    for (dead.items) |d| {
        try t.expect(!d.id.eql(.{ .file = file_id, .local = x }));
        try t.expect(!d.id.eql(.{ .file = file_id, .local = y }));
        try t.expect(!d.id.eql(.{ .file = file_id, .local = total }));
        if (d.id.eql(.{ .file = file_id, .local = dead_fn })) found_parent = d.nested;
    }
    try t.expectEqual(@as(?usize, 3), found_parent);
}

test "an anytype parameter of a dead function rolls up into its parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn call_cb(cb: anytype) void {
        \\    cb(1);
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

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const call_cb = semantic.symbols.getSymbolNamed("call_cb").?;
    const cb = semantic.symbols.getSymbolNamed("cb").?;

    var found_parent: ?usize = null;
    for (dead.items) |d| {
        try t.expect(!d.id.eql(.{ .file = file_id, .local = cb }));
        if (d.id.eql(.{ .file = file_id, .local = call_cb })) found_parent = d.nested;
    }
    try t.expectEqual(@as(?usize, 1), found_parent);
}

test "a symbol only referenced from a test block is dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn only_used_in_test() void {}
        \\fn comptimeHelper() comptime_int { return 1; }
        \\fn used() void {}
        \\pub fn main() void { used(); }
        \\
        \\test "covers only_used_in_test" {
        \\    only_used_in_test();
        \\    comptime {
        \\        _ = comptimeHelper();
        \\    }
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
    const helper = semantic.symbols.getSymbolNamed("comptimeHelper").?;
    const used = semantic.symbols.getSymbolNamed("used").?;
    try t.expect(!reachability.isReachable(.{ .file = file_id, .local = target }));
    try t.expect(!reachability.isReachable(.{ .file = file_id, .local = helper }));
    try t.expect(reachability.isReachable(.{ .file = file_id, .local = used }));

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), dead.items.len);
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

test "a struct field only reached by comptime reflection stays reachable through its container" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "rules.zig",
        \\pub const DuplicateCase = struct {
        \\    pub fn run() void {}
        \\};
        \\
    );
    try writeFile(tmp.dir, "main.zig",
        \\const rules = @import("rules.zig");
        \\
        \\fn RuleConfig(comptime T: type) type {
        \\    return struct {
        \\        pub fn run(self: @This()) void {
        \\            _ = self;
        \\            T.run();
        \\        }
        \\    };
        \\}
        \\
        \\const Rules = struct {
        \\    duplicate_case: RuleConfig(rules.DuplicateCase) = .{},
        \\};
        \\
        \\pub fn main() void {
        \\    const cfg: Rules = .{};
        \\    _ = cfg;
        \\}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const main_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(main_id).semantic;
    const duplicate_case = semantic.symbols.getSymbolNamed("duplicate_case").?;
    try t.expect(reachability.isReachable(.{ .file = main_id, .local = duplicate_case }));

    for (project.files.items) |f| {
        if (!std.mem.endsWith(u8, f.path, "rules.zig")) continue;
        const duplicate_case_ty = f.semantic.symbols.getSymbolNamed("DuplicateCase").?;
        try t.expect(reachability.isReachable(.{ .file = f.id, .local = duplicate_case_ty }));
    }
}

test "named parameters of a bare fn-type field are never reported dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Handler = struct {
        \\    on_data: *const fn (ctx: *anyopaque, conn: u32, bytes: []const u8) void,
        \\};
        \\
        \\pub fn main() void {
        \\    var h: Handler = undefined;
        \\    _ = &h;
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

    var dead = try reachability.deadSymbols(t.allocator, &project);
    defer dead.deinit(t.allocator);

    const semantic = &project.file(file_id).semantic;
    const ctx = semantic.symbols.getSymbolNamed("ctx").?;
    const conn = semantic.symbols.getSymbolNamed("conn").?;
    const bytes = semantic.symbols.getSymbolNamed("bytes").?;

    for (dead.items) |d| {
        try t.expect(!d.id.eql(.{ .file = file_id, .local = ctx }));
        try t.expect(!d.id.eql(.{ .file = file_id, .local = conn }));
        try t.expect(!d.id.eql(.{ .file = file_id, .local = bytes }));
    }
}

test "fields of an anonymous struct returned from a reachable function stay reachable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\fn get_or_create() !struct { channel_id: u32, created: bool } {
        \\    return .{ .channel_id = 1, .created = true };
        \\}
        \\
        \\pub fn main() void {
        \\    _ = get_or_create() catch return;
        \\}
        \\
    );
    const root_path = try tmp.dir.realpathAlloc(t.allocator, "main.zig");
    defer t.allocator.free(root_path);

    var project: Project = .init(t.allocator);
    defer project.deinit();

    const main_id = try project.addRoot(root_path);

    var roots = try Roots.build(t.allocator, &project, .analyze);
    defer roots.deinit(t.allocator);

    var cross_file = try Resolver.build(t.allocator, &project);
    defer cross_file.deinit(t.allocator);

    var reachability = try Reachability.build(t.allocator, &project, &roots, &cross_file);
    defer reachability.deinit(t.allocator);

    const semantic = &project.file(main_id).semantic;
    const channel_id = semantic.symbols.getSymbolNamed("channel_id").?;
    const created = semantic.symbols.getSymbolNamed("created").?;

    try t.expect(reachability.isReachable(.{ .file = main_id, .local = channel_id }));
    try t.expect(reachability.isReachable(.{ .file = main_id, .local = created }));
}

test "parameters, locals and fields are never findings of their own" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Config = struct {
        \\    unused_field: u32 = 0,
        \\    pub fn make() Config {
        \\        return .{};
        \\    }
        \\};
        \\fn f(param: u32, unused_param: u32) void {
        \\    const local = param;
        \\    const unused_local = 1;
        \\    _ = local;
        \\}
        \\pub fn main() void {
        \\    f(1, 2);
        \\    _ = Config.make();
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

    for (dead.items) |d| {
        std.debug.print("unexpected finding: {s}\n", .{project.symbol(d.id).name});
    }
    try t.expectEqual(@as(usize, 0), dead.items.len);
}

test "a decl literal (.init(...) / return .empty / field default) reaches the member of the expected type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Roots = struct {
        \\    n: u32 = 0,
        \\    pub const empty: Roots = .{};
        \\    pub const other: Roots = .{ .n = 1 };
        \\    pub fn init(n: u32) Roots { return .{ .n = n }; }
        \\    pub fn make() Roots { return .empty; }
        \\    pub fn unusedInit() Roots { return .{}; }
        \\};
        \\const Holder = struct {
        \\    roots: Roots = .init(2),
        \\};
        \\pub fn main() void {
        \\    const r = Roots.make();
        \\    _ = r;
        \\    var h: Holder = .{};
        \\    _ = &h;
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

    try t.expectEqual(@as(usize, 2), dead.items.len);
    for (dead.items) |d| {
        const name = project.symbol(d.id).name;
        try t.expect(std.mem.eql(u8, name, "other") or std.mem.eql(u8, name, "unusedInit"));
    }
}

test "what a possibly-reached symbol uses is possibly reached, not dead" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "main.zig",
        \\const Foo = struct {
        \\    pub fn bar() void {
        \\        helper();
        \\    }
        \\};
        \\pub fn main() void {
        \\    const name = getName();
        \\    @field(Foo, name)();
        \\}
        \\fn helper() void {}
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
    const helper = semantic.symbols.getSymbolNamed("helper").?;

    try t.expect(!reachability.isReachable(.{ .file = file_id, .local = helper }));
    try t.expect(reachability.isPossiblyReachable(.{ .file = file_id, .local = helper }));
}
