//! Phase 14: locally-typed variable -> declared-type symbol resolution.

const std = @import("std");
const t = std.testing;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const InstanceType = @import("InstanceType.zig");
const OwnerMap = @import("OwnerMap.zig");

fn build(src: [:0]const u8) !Semantic {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();
    var result = try builder.build(src);
    result.errors.deinit(t.allocator);
    return result.value;
}

test "explicit type annotation resolves to the annotated type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s: Foo = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, s_id).?);
}

test "explicitly-typed struct-literal initializer resolves to the type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s = Foo{};
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, s_id).?);
}

test "same-file field-access type chain resolves through a nested container" {
    var sem = try build(
        \\const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub fn run(self: *Inner) void { _ = self; }
        \\    };
        \\};
        \\fn a() void {
        \\    var s: Outer.Inner = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const inner_id = sem.symbols.getSymbolNamed("Inner").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;

    try t.expectEqual(inner_id, InstanceType.resolve(&sem, &owner_map, s_id).?);
}

test "a variable with no statically-named type resolves to null" {
    var sem = try build(
        \\fn makeFoo() i32 { return 0; }
        \\fn a() void {
        \\    var s = makeFoo();
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const s_id = sem.symbols.getSymbolNamed("s").?;
    try t.expectEqual(@as(?Semantic.Symbol.Id, null), InstanceType.resolve(&sem, &owner_map, s_id));
}

test "crossFileRoot finds the base and field of a single field-access type annotation" {
    var sem = try build(
        \\const storage = 0;
        \\fn a() void {
        \\    var s: storage.Widget = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const storage_id = sem.symbols.getSymbolNamed("storage").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;
    const root = InstanceType.crossFileRoot(&sem, &owner_map, s_id).?;
    try t.expectEqual(storage_id, root.base);
    try t.expectEqualStrings("Widget", root.field);
}

test "crossFileRoot returns null for a bare identifier type (not a field-access chain)" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s: Foo = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const s_id = sem.symbols.getSymbolNamed("s").?;
    try t.expectEqual(@as(?InstanceType.CrossFileRoot, null), InstanceType.crossFileRoot(&sem, &owner_map, s_id));
}

test "crossFileRoot resolves a same-file chain leading up to the import-crossing hop" {
    var sem = try build(
        \\const mod = struct {
        \\    pub const storage = 0;
        \\};
        \\fn a() void {
        \\    var s: mod.storage.Widget = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const storage_id = sem.symbols.getSymbolNamed("storage").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;
    const root = InstanceType.crossFileRoot(&sem, &owner_map, s_id).?;
    try t.expectEqual(storage_id, root.base);
    try t.expectEqualStrings("Widget", root.field);
}

test "a pointer-typed self parameter resolves to its declared type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\    pub fn visit(self: *Foo) void { self.run(); }
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const self_id = sem.symbols.getSymbolNamed("self").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, self_id).?);
}

test "a by-value typed parameter resolves to its declared type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: Foo) void { _ = self; }
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const self_id = sem.symbols.getSymbolNamed("self").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, self_id).?);
}

test "crossFileRoot finds the base and field of a field-access-typed parameter" {
    var sem = try build(
        \\const storage = 0;
        \\fn a(self: *storage.Widget) void { _ = self; }
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const storage_id = sem.symbols.getSymbolNamed("storage").?;
    const self_id = sem.symbols.getSymbolNamed("self").?;
    const root = InstanceType.crossFileRoot(&sem, &owner_map, self_id).?;
    try t.expectEqual(storage_id, root.base);
    try t.expectEqualStrings("Widget", root.field);
}

test "a parameter with no statically-named type resolves to null" {
    var sem = try build(
        \\fn a(x: anytype) void { _ = x; }
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const x_id = sem.symbols.getSymbolNamed("x").?;
    try t.expectEqual(@as(?Semantic.Symbol.Id, null), InstanceType.resolve(&sem, &owner_map, x_id));
}

test "a container field's own type annotation resolves to the annotated type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\const Holder = struct {
        \\    foo: Foo,
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const field_id = sem.symbols.getSymbolNamed("foo").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, field_id).?);
}

test "crossFileRoot finds the base and field of a cross-file-typed container field" {
    var sem = try build(
        \\const storage = 0;
        \\const Holder = struct {
        \\    foo: storage.Widget,
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const storage_id = sem.symbols.getSymbolNamed("storage").?;
    const field_id = sem.symbols.getSymbolNamed("foo").?;
    const root = InstanceType.crossFileRoot(&sem, &owner_map, field_id).?;
    try t.expectEqual(storage_id, root.base);
    try t.expectEqualStrings("Widget", root.field);
}

test "an if-payload capture of an optional field resolves to the field's unwrapped type" {
    var sem = try build(
        \\const MetaLog = struct {
        \\    pub fn append(self: *MetaLog) void { _ = self; }
        \\};
        \\const State = struct {
        \\    meta_log: ?MetaLog,
        \\    pub fn meta_append(self: *State) void {
        \\        if (self.meta_log) |*log| log.append();
        \\    }
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const meta_log_ty = sem.symbols.getSymbolNamed("MetaLog").?;
    const log_id = sem.symbols.getSymbolNamed("log").?;

    try t.expectEqual(meta_log_ty, InstanceType.resolve(&sem, &owner_map, log_id).?);
}

test "an if-payload capture of a cross-file-typed optional field surfaces a crossFileRoot" {
    var sem = try build(
        \\const ml = 0;
        \\const State = struct {
        \\    meta_log: ?ml.MetaLog,
        \\    pub fn meta_append(self: *State) void {
        \\        if (self.meta_log) |*log| log.append();
        \\    }
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const ml_id = sem.symbols.getSymbolNamed("ml").?;
    const log_id = sem.symbols.getSymbolNamed("log").?;

    const root = InstanceType.crossFileRoot(&sem, &owner_map, log_id).?;
    try t.expectEqual(ml_id, root.base);
    try t.expectEqualStrings("MetaLog", root.field);
}

test "an error-branch payload (`else |err|`) is not treated as an optional payload" {
    var sem = try build(
        \\const Foo = struct {};
        \\fn a() !void {
        \\    const x: anyerror!Foo = error.Oops;
        \\    if (x) |_| {} else |err| {
        \\        _ = err;
        \\    }
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const err_id = sem.symbols.getSymbolNamed("err").?;
    try t.expectEqual(@as(?Semantic.Symbol.Id, null), InstanceType.resolve(&sem, &owner_map, err_id));
}

test "a while-payload capture of an optional field resolves to the field's unwrapped type" {
    var sem = try build(
        \\const MetaLog = struct {
        \\    pub fn append(self: *MetaLog) void { _ = self; }
        \\};
        \\const State = struct {
        \\    meta_log: ?MetaLog,
        \\    pub fn meta_append(self: *State) void {
        \\        while (self.meta_log) |*log| { log.append(); break; }
        \\    }
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const meta_log_ty = sem.symbols.getSymbolNamed("MetaLog").?;
    const log_id = sem.symbols.getSymbolNamed("log").?;

    try t.expectEqual(meta_log_ty, InstanceType.resolve(&sem, &owner_map, log_id).?);
}

test "a for-payload capture over a slice-typed field resolves to the element type" {
    var sem = try build(
        \\const T = struct {
        \\    pub fn go(self: *T) void { _ = self; }
        \\};
        \\const Holder = struct { items: []T };
        \\pub fn run() void {
        \\    var h: Holder = undefined;
        \\    for (h.items) |it| { it.go(); }
        \\    _ = &h;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const t_ty = sem.symbols.getSymbolNamed("T").?;
    const it_id = sem.symbols.getSymbolNamed("it").?;

    try t.expectEqual(t_ty, InstanceType.resolve(&sem, &owner_map, it_id).?);
}

test "a for-payload by-reference capture (`|*x|`) over a slice-typed local resolves to the element type" {
    var sem = try build(
        \\const T = struct {
        \\    pub fn go(self: *T) void { _ = self; }
        \\};
        \\pub fn run() void {
        \\    var ls: []T = undefined;
        \\    for (ls) |*it| { it.go(); }
        \\    _ = &ls;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const t_ty = sem.symbols.getSymbolNamed("T").?;
    const it_id = sem.symbols.getSymbolNamed("it").?;

    try t.expectEqual(t_ty, InstanceType.resolve(&sem, &owner_map, it_id).?);
}

test "a multi-capture for loop matches each payload to its own input positionally" {
    var sem = try build(
        \\const T = struct {
        \\    pub fn go(self: *T) void { _ = self; }
        \\};
        \\pub fn run() void {
        \\    var ls: []T = undefined;
        \\    for (ls, 0..) |*it, i| { it.go(); _ = i; }
        \\    _ = &ls;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const t_ty = sem.symbols.getSymbolNamed("T").?;
    const it_id = sem.symbols.getSymbolNamed("it").?;
    const i_id = sem.symbols.getSymbolNamed("i").?;

    try t.expectEqual(t_ty, InstanceType.resolve(&sem, &owner_map, it_id).?);
    try t.expectEqual(@as(?Semantic.Symbol.Id, null), InstanceType.resolve(&sem, &owner_map, i_id));
}

test "a for-payload capture of a cross-file-typed slice element surfaces a crossFileRoot" {
    var sem = try build(
        \\const t = 0;
        \\const Holder = struct { items: []t.T };
        \\pub fn run() void {
        \\    var h: Holder = undefined;
        \\    for (h.items) |it| { it.go(); }
        \\    _ = &h;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const t_id = sem.symbols.getSymbolNamed("t").?;
    const it_id = sem.symbols.getSymbolNamed("it").?;

    const root = InstanceType.crossFileRoot(&sem, &owner_map, it_id).?;
    try t.expectEqual(t_id, root.base);
    try t.expectEqualStrings("T", root.field);
}

test "a pointer-typed local resolves to its declared type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s: *Foo = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, s_id).?);
}

test "a const-pointer-typed local resolves to its declared type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s: *const Foo = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, s_id).?);
}

test "a slice-typed local resolves to its declared element type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s: []Foo = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, s_id).?);
}

test "an array-typed local resolves to its declared element type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s: [4]Foo = undefined;
        \\    _ = &s;
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, s_id).?);
}

test "a pointer-typed container field resolves to its declared type's symbol" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\const Holder = struct {
        \\    foo: *Foo,
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const field_id = sem.symbols.getSymbolNamed("foo").?;

    try t.expectEqual(foo_id, InstanceType.resolve(&sem, &owner_map, field_id).?);
}

test "crossFileRoot finds the base and field of a pointer-typed container field" {
    var sem = try build(
        \\const storage = 0;
        \\const Holder = struct {
        \\    foo: *storage.Widget,
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const storage_id = sem.symbols.getSymbolNamed("storage").?;
    const field_id = sem.symbols.getSymbolNamed("foo").?;
    const root = InstanceType.crossFileRoot(&sem, &owner_map, field_id).?;
    try t.expectEqual(storage_id, root.base);
    try t.expectEqualStrings("Widget", root.field);
}

test "a non-variable symbol resolves to null" {
    var sem = try build(
        \\const Foo = struct {};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    try t.expectEqual(@as(?Semantic.Symbol.Id, null), InstanceType.resolve(&sem, &owner_map, foo_id));
}
