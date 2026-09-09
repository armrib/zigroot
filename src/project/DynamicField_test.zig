//! Phase 9: `@field(Container, name)` dynamic field access.

const std = @import("std");
const t = std.testing;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const DynamicField = @import("DynamicField.zig");

fn build(src: [:0]const u8) !Semantic {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();
    var result = try builder.build(src);
    result.errors.deinit(t.allocator);
    return result.value;
}

fn fooReference(sem: *const Semantic, foo_id: Semantic.Symbol.Id) Semantic.Ast.Node.Index {
    var ref_it = sem.symbols.iterReferences(foo_id);
    return ref_it.next().?.node;
}

test "@field(Foo, \"bar\") resolves to Foo's bar export at .possible confidence" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn bar() void {}
        \\};
        \\fn a() void { @field(Foo, "bar")(); }
        \\
    );
    defer sem.deinit();

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const bar_id = sem.symbols.getSymbolNamed("bar").?;

    const resolution = DynamicField.resolve(&sem, foo_id, fooReference(&sem, foo_id)).?;
    try t.expectEqual(bar_id, resolution.possible);
}

test "@field(Foo, name) with a runtime name resolves to every export of Foo" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn bar() void {}
        \\    pub fn baz() void {}
        \\};
        \\fn a(name: []const u8) void { @field(Foo, name)(); }
        \\
    );
    defer sem.deinit();

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const bar_id = sem.symbols.getSymbolNamed("bar").?;
    const baz_id = sem.symbols.getSymbolNamed("baz").?;

    const resolution = DynamicField.resolve(&sem, foo_id, fooReference(&sem, foo_id)).?;
    const exports = resolution.unknown;
    try t.expectEqual(@as(usize, 2), exports.len);
    try t.expect(std.mem.indexOfScalar(Semantic.Symbol.Id, exports, bar_id) != null);
    try t.expect(std.mem.indexOfScalar(Semantic.Symbol.Id, exports, baz_id) != null);
}

test "a plain field access (not @field) is not resolved by DynamicField" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn bar() void {}
        \\};
        \\fn a() void { Foo.bar(); }
        \\
    );
    defer sem.deinit();

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    try t.expectEqual(@as(?DynamicField.Resolution, null), DynamicField.resolve(&sem, foo_id, fooReference(&sem, foo_id)));
}
