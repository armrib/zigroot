//! Phase 4: same-file `Symbol -> Symbol` declaration graph.

const std = @import("std");
const t = std.testing;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const OwnerMap = @import("OwnerMap.zig");
const SymbolGraph = @import("SymbolGraph.zig");
const FileId = @import("FileId.zig").FileId;

fn build(src: [:0]const u8) !Semantic {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();
    var result = try builder.build(src);
    result.errors.deinit(t.allocator);
    return result.value;
}

test "a call within one function's body produces an edge to the called function" {
    var sem = try build(
        \\fn a() void { b(); }
        \\fn b() void {}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const b_id = sem.symbols.getSymbolNamed("b").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    try t.expectEqual(@as(usize, 1), outgoing.len);
    try t.expect(outgoing[0].to.eql(.{ .file = file, .local = b_id }));
}

test "a reference nested inside a block still edges from the enclosing function" {
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

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const b_id = sem.symbols.getSymbolNamed("b").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    try t.expectEqual(@as(usize, 1), outgoing.len);
    try t.expect(outgoing[0].to.eql(.{ .file = file, .local = b_id }));
}

test "Foo.bar() edges to both Foo and Foo's exported bar" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn bar() void {}
        \\};
        \\fn a() void { Foo.bar(); }
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const bar_id = sem.symbols.getSymbolNamed("bar").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    try t.expectEqual(@as(usize, 2), outgoing.len);
    try t.expect(outgoing[0].to.eql(.{ .file = file, .local = foo_id }));
    try t.expect(outgoing[1].to.eql(.{ .file = file, .local = bar_id }));
}

test "Outer.Inner.run() chains through two nested containers" {
    var sem = try build(
        \\const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub fn run() void {}
        \\    };
        \\};
        \\fn a() void { Outer.Inner.run(); }
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const run_id = sem.symbols.getSymbolNamed("run").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var found_run = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = run_id })) found_run = true;
    }
    try t.expect(found_run);
}

test "s.run() on an explicitly-typed variable edges to the type's run at .possible confidence" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn run(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var s: Foo = undefined;
        \\    s.run();
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const run_id = sem.symbols.getSymbolNamed("run").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var found: ?SymbolGraph.Target = null;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = run_id })) found = edge;
    }
    try t.expect(found != null);
    try t.expectEqual(SymbolGraph.EdgeKind.possible, found.?.kind);
}

test "self.helper() inside a method taking self: *Foo edges to Foo's helper at .possible confidence" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn helper(self: *Foo) void { _ = self; }
        \\    pub fn visit(self: *Foo) void { self.helper(); }
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const visit_id = sem.symbols.getSymbolNamed("visit").?;
    const helper_id = sem.symbols.getSymbolNamed("helper").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = visit_id });
    var found: ?SymbolGraph.Target = null;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = helper_id })) found = edge;
    }
    try t.expect(found != null);
    try t.expectEqual(SymbolGraph.EdgeKind.possible, found.?.kind);
}

test "@field(Foo, \"Bar\").baz() chains from the @field hop into a further .field hop" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub const Bar = struct {
        \\        pub fn baz() void {}
        \\    };
        \\};
        \\fn a() void { @field(Foo, "Bar").baz(); }
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const baz_id = sem.symbols.getSymbolNamed("baz").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var found: ?SymbolGraph.Target = null;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = baz_id })) found = edge;
    }
    try t.expect(found != null);
    try t.expectEqual(SymbolGraph.EdgeKind.possible, found.?.kind);
}

test "@field(Outer.Inner, \"run\") resolves through a FieldChain-resolved container" {
    var sem = try build(
        \\const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub fn run() void {}
        \\    };
        \\};
        \\fn a() void { @field(Outer.Inner, "run")(); }
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    const run_id = sem.symbols.getSymbolNamed("run").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var found = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = run_id })) found = true;
    }
    try t.expect(found);
}

test "an unreferenced declaration has no outgoing edges" {
    var sem = try build(
        \\fn a() void {}
        \\fn b() void {}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const a_id = sem.symbols.getSymbolNamed("a").?;
    try t.expectEqual(@as(usize, 0), graph.outgoing(.{ .file = file, .local = a_id }).len);
}
