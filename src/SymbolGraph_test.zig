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

test "a nested const Self = @This(); alias resolves through its own container's exports" {
    var sem = try build(
        \\const Outer = struct {
        \\    pub const Inner = struct {
        \\        const Self = @This();
        \\        pub fn run() void {}
        \\    };
        \\};
        \\fn a() void { Outer.Inner.Self.run(); }
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

test "a container edges to each of its own fields" {
    var sem = try build(
        \\const Foo = struct {
        \\    bar: u32 = 0,
        \\    baz: u32 = 0,
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const foo_id = sem.symbols.getSymbolNamed("Foo").?;
    const bar_id = sem.symbols.getSymbolNamed("bar").?;
    const baz_id = sem.symbols.getSymbolNamed("baz").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = foo_id });
    var found_bar = false;
    var found_baz = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = bar_id })) found_bar = true;
        if (edge.to.eql(.{ .file = file, .local = baz_id })) found_baz = true;
    }
    try t.expect(found_bar);
    try t.expect(found_baz);
}

test "a field's type expression edges from the field, reachable through its container" {
    var sem = try build(
        \\fn Registry(comptime T: type) type {
        \\    return struct { value: T = undefined };
        \\}
        \\const Rule = struct {};
        \\const Rules = struct {
        \\    entry: Registry(Rule) = .{},
        \\};
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const rules_id = sem.symbols.getSymbolNamed("Rules").?;
    const entry_id = sem.symbols.getSymbolNamed("entry").?;
    const rule_id = sem.symbols.getSymbolNamed("Rule").?;

    const from_rules = graph.outgoing(.{ .file = file, .local = rules_id });
    var reaches_entry = false;
    for (from_rules) |edge| {
        if (edge.to.eql(.{ .file = file, .local = entry_id })) reaches_entry = true;
    }
    try t.expect(reaches_entry);

    const from_entry = graph.outgoing(.{ .file = file, .local = entry_id });
    var reaches_rule = false;
    for (from_entry) |edge| {
        if (edge.to.eql(.{ .file = file, .local = rule_id })) reaches_rule = true;
    }
    try t.expect(reaches_rule);
}

test "a function edges to the fields of an anonymous struct in its return type" {
    var sem = try build(
        \\fn anon_ret() struct { anon_field: bool } {
        \\    return .{ .anon_field = true };
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const anon_ret_id = sem.symbols.getSymbolNamed("anon_ret").?;
    const anon_field_id = sem.symbols.getSymbolNamed("anon_field").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = anon_ret_id });
    var found = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = anon_field_id })) found = true;
    }
    try t.expect(found);
}

test "a function edges to the fields of an anonymous struct behind its error-union return type" {
    var sem = try build(
        \\fn anon_ret() !struct { anon_field: bool } {
        \\    return .{ .anon_field = true };
        \\}
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const anon_ret_id = sem.symbols.getSymbolNamed("anon_ret").?;
    const anon_field_id = sem.symbols.getSymbolNamed("anon_field").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = anon_ret_id });
    var found = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = anon_field_id })) found = true;
    }
    try t.expect(found);
}

test "a function edges to the fields of an anonymous struct in a parameter's type" {
    var sem = try build(
        \\fn f(p: struct { anon_field: bool }) void { _ = p; }
        \\
    );
    defer sem.deinit();

    var owner_map = try OwnerMap.build(t.allocator, &sem);
    defer owner_map.deinit(t.allocator);

    const file: FileId = .fromIndex(0);
    var graph = try SymbolGraph.build(t.allocator, file, &sem, &owner_map);
    defer graph.deinit(t.allocator);

    const f_id = sem.symbols.getSymbolNamed("f").?;
    const anon_field_id = sem.symbols.getSymbolNamed("anon_field").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = f_id });
    var found = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = anon_field_id })) found = true;
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

test "an instance method reached through a struct field edges to the method" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn helper(self: *Foo) void { _ = self; }
        \\};
        \\const Holder = struct {
        \\    foo: Foo,
        \\};
        \\fn a() void {
        \\    var h: Holder = undefined;
        \\    h.foo.helper();
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
    const helper_id = sem.symbols.getSymbolNamed("helper").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var reaches_helper = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = helper_id })) reaches_helper = true;
    }
    try t.expect(reaches_helper);
}

test "an instance method reached through an indexed array-field element edges to the method" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn helper(self: *Foo) void { _ = self; }
        \\};
        \\const Holder = struct {
        \\    arr: [4]Foo,
        \\};
        \\fn a() void {
        \\    var h: Holder = undefined;
        \\    h.arr[0].helper();
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
    const helper_id = sem.symbols.getSymbolNamed("helper").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var reaches_helper = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = helper_id })) reaches_helper = true;
    }
    try t.expect(reaches_helper);
}

test "an instance method reached through a &-taken indexed array-field element edges to the method" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn helper(self: *Foo) void { _ = self; }
        \\};
        \\const Holder = struct {
        \\    arr: [4]Foo,
        \\};
        \\fn a() void {
        \\    var h: Holder = undefined;
        \\    const c = &h.arr[1];
        \\    c.helper();
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
    const helper_id = sem.symbols.getSymbolNamed("helper").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var reaches_helper = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = helper_id })) reaches_helper = true;
    }
    try t.expect(reaches_helper);
}

test "an instance method reached through an indexed local array edges to the method" {
    var sem = try build(
        \\const Foo = struct {
        \\    pub fn helper(self: *Foo) void { _ = self; }
        \\};
        \\fn a() void {
        \\    var la: [2]Foo = undefined;
        \\    la[0].helper();
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
    const helper_id = sem.symbols.getSymbolNamed("helper").?;

    const outgoing = graph.outgoing(.{ .file = file, .local = a_id });
    var reaches_helper = false;
    for (outgoing) |edge| {
        if (edge.to.eql(.{ .file = file, .local = helper_id })) reaches_helper = true;
    }
    try t.expect(reaches_helper);
}
