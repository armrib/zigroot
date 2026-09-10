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

    const storage_id = sem.symbols.getSymbolNamed("storage").?;
    const s_id = sem.symbols.getSymbolNamed("s").?;
    const root = InstanceType.crossFileRoot(&sem, s_id).?;
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

    const s_id = sem.symbols.getSymbolNamed("s").?;
    try t.expectEqual(@as(?InstanceType.CrossFileRoot, null), InstanceType.crossFileRoot(&sem, s_id));
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

    const storage_id = sem.symbols.getSymbolNamed("storage").?;
    const self_id = sem.symbols.getSymbolNamed("self").?;
    const root = InstanceType.crossFileRoot(&sem, self_id).?;
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
