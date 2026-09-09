//! Phase 3: node -> containing-declaration map.

const std = @import("std");
const t = std.testing;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const OwnerMap = @import("OwnerMap.zig");

fn build(src: [:0]const u8) !Semantic {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();
    var result = try builder.build(src);
    result.errors.deinit(t.allocator);
    return result.value;
}

test "a reference inside a function body is owned by that function" {
    var sem = try build(
        \\fn a() void { b(); }
        \\fn b() void {}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const b_id = sem.symbols.getSymbolNamed("b").?;

    const refs = sem.symbols.getReferences(b_id);
    try t.expect(refs.len > 0);
    const ref = sem.symbols.getReference(refs[0]);

    const owner = owner_map.get(ref.node);
    try t.expect(owner != null);
    try t.expect(owner.?.eql(a_id));
}

test "a reference nested inside a block is still owned by the enclosing function" {
    var sem = try build(
        \\fn a() void {
        \\    if (true) {
        \\        b();
        \\    }
        \\}
        \\fn b() void {}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const b_id = sem.symbols.getSymbolNamed("b").?;

    const refs = sem.symbols.getReferences(b_id);
    try t.expect(refs.len > 0);
    const ref = sem.symbols.getReference(refs[0]);

    const owner = owner_map.get(ref.node);
    try t.expect(owner != null);
    try t.expect(owner.?.eql(a_id));
}

test "a top-level declaration's initializer is owned by that declaration" {
    var sem = try build(
        \\fn compute() u32 { return 1; }
        \\const x = compute();
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const x_id = sem.symbols.getSymbolNamed("x").?;
    const compute_id = sem.symbols.getSymbolNamed("compute").?;

    const refs = sem.symbols.getReferences(compute_id);
    try t.expect(refs.len > 0);
    const ref = sem.symbols.getReference(refs[0]);

    const owner = owner_map.get(ref.node);
    try t.expect(owner != null);
    try t.expect(owner.?.eql(x_id));
}

test "a top-level declaration's own node has no owner" {
    var sem = try build("fn a() void {}\n");
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const a_sym = sem.symbols.get(a_id);

    try t.expectEqual(@as(?Semantic.Symbol.Id, null), owner_map.get(a_sym.decl));
}
