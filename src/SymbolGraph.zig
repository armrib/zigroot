//! Same-file `Symbol -> Symbol` reference graph.
//!
//! ZLint's `Semantic` already links every reference to the symbol it
//! resolves to (`Symbol.Table.getReferences`/`iterReferences`), but that's
//! backwards for reachability: we need to know which *declaration* did the
//! referencing, not just what got referenced. `OwnerMap` (Phase 3) answers
//! that — the nearest enclosing declaration of a reference's node — so
//! inverting `Reference -> Symbol` into `Symbol -> Symbol` is just: for
//! every reference to a symbol, look up its owner and add an edge
//! `owner -> referenced symbol`.
//!
//! Scoped to one file for now. Cross-file edges (`storage.start()`) are
//! Phase 6's `Resolver`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");

const FileId = @import("FileId.zig").FileId;
const OwnerMap = @import("OwnerMap.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;
const FieldChain = @import("FieldChain.zig");
const InstanceType = @import("InstanceType.zig");
const Semantic = zlint.Semantic;

const SymbolGraph = @This();

/// Phase 9: how confidently an edge's target was resolved.
///
/// - `definite`: a direct reference, or a `FieldChain`-resolved
///   `container.member` access — the compiler-guaranteed static shape.
/// - `possible`: resolved, but via a less-exercised path (e.g.
///   `@field(Foo, "bar")` with a comptime-known name).
/// - `unknown`: no single target could be determined statically (e.g.
///   `@field(Foo, name)` with a runtime name) — the edge names every
///   plausible target rather than being dropped.
pub const EdgeKind = enum { definite, possible, unknown };

pub const Edge = struct {
    from: SymbolId,
    to: SymbolId,
    node: Semantic.Ast.Node.Index,
    kind: EdgeKind,
};

pub const Target = struct {
    to: SymbolId,
    kind: EdgeKind,
};

edges: std.ArrayListUnmanaged(Edge) = .empty,
/// from -> [(to, kind), ...]
adjacency: std.AutoHashMapUnmanaged(SymbolId, std.ArrayListUnmanaged(Target)) = .empty,

pub const empty: SymbolGraph = .{};

pub fn deinit(self: *SymbolGraph, gpa: Allocator) void {
    self.edges.deinit(gpa);
    var it = self.adjacency.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    self.adjacency.deinit(gpa);
    self.* = undefined;
}

pub fn addEdge(self: *SymbolGraph, gpa: Allocator, from: SymbolId, to: SymbolId, node: Semantic.Ast.Node.Index, kind: EdgeKind) !void {
    try self.edges.append(gpa, .{ .from = from, .to = to, .node = node, .kind = kind });
    const gop = try self.adjacency.getOrPut(gpa, from);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(gpa, .{ .to = to, .kind = kind });
}

/// Symbols directly referenced from `from`'s declaration body, with the
/// confidence each was resolved at. Empty slice if `from` isn't known to
/// reference anything.
pub fn outgoing(self: *const SymbolGraph, from: SymbolId) []const Target {
    if (self.adjacency.get(from)) |list| return list.items;
    return &.{};
}

/// Builds the same-file graph for `file`: for every symbol, every
/// reference to it, mapped through `owner_map` to the declaration the
/// reference occurs in. References with no owner (outside any declaration)
/// are skipped.
///
/// A reference used as the base of a `container.member` chain, or as the
/// container argument of `@field(...)`, also gets an edge straight to the
/// innermost resolved export, alongside the direct edge to the container
/// itself — so `Foo.bar()` reaches both `Foo` and `bar`. Phase 13's
/// `FieldChain.resolveChain` interleaves both hop kinds, so a chain can
/// freely mix `.field` and `@field(...)` hops (`@field(Foo, "Bar").baz()`),
/// downgrading to `.possible` for the rest of the chain once a
/// comptime-known `@field` hop is taken. A runtime-named `@field` hop can't
/// be chased further — every export of the container at that point becomes
/// an `.unknown` edge instead.
///
/// Phase 14: if the referenced symbol is a variable whose declared type
/// `InstanceType.resolve` can name (an explicit type annotation or a typed
/// struct-literal initializer), the same chain-walk also runs starting from
/// that type instead of the variable itself, at `.possible` confidence —
/// `var s: Foo = ...; s.run();` reaches `Foo.run`, since ZLint's exports
/// already include instance methods (it doesn't yet separate them from
/// static ones). Skipped when `InstanceType.resolve` can't determine a
/// type, e.g. a variable initialized from a function's return value.
///
/// Phase 21: every container symbol also gets a `.definite` edge to each of
/// its own fields (ZLint's `Symbol.members`), regardless of whether
/// anything ever references a field by name. A struct field's type is part
/// of its container's type — Zig resolves every field when the container
/// type is used, whether or not the field is ever named directly — so a
/// comptime-reflection-driven registry (`inline for (std.meta.fields(Rules))
/// |f| ...`) doesn't strand its fields' own referenced symbols as dead just
/// because no ordinary reference names the field.
pub fn build(gpa: Allocator, file: FileId, semantic: *const Semantic, owner_map: *const OwnerMap) Allocator.Error!SymbolGraph {
    var graph: SymbolGraph = .empty;
    errdefer graph.deinit(gpa);

    var sym_it = semantic.symbols.iter();
    while (sym_it.next()) |sym_id| {
        const instance_ty = InstanceType.resolve(semantic, owner_map, sym_id);

        var ref_it = semantic.symbols.iterReferences(sym_id);
        while (ref_it.next()) |ref| {
            const owner = owner_map.get(ref.node) orelse continue;
            const owner_id: SymbolId = .{ .file = file, .local = owner };
            try graph.addEdge(gpa, owner_id, .{ .file = file, .local = sym_id }, ref.node, .definite);

            const chain = FieldChain.resolveChain(semantic, semantic, owner_map, sym_id, ref.node, .definite);
            if (chain.result.symbol != sym_id) {
                const kind: EdgeKind = switch (chain.result.kind) {
                    .definite => .definite,
                    .possible => .possible,
                };
                try graph.addEdge(gpa, owner_id, .{ .file = file, .local = chain.result.symbol }, chain.result.node, kind);
            }
            if (chain.unknown) |unknown| for (unknown.exports) |target| {
                try graph.addEdge(gpa, owner_id, .{ .file = file, .local = target }, unknown.node, .unknown);
            };

            if (instance_ty) |ty| {
                const inst_chain = FieldChain.resolveChain(semantic, semantic, owner_map, ty, ref.node, .possible);
                if (inst_chain.result.symbol != ty) {
                    try graph.addEdge(gpa, owner_id, .{ .file = file, .local = inst_chain.result.symbol }, inst_chain.result.node, .possible);
                }
                if (inst_chain.unknown) |unknown| for (unknown.exports) |target| {
                    try graph.addEdge(gpa, owner_id, .{ .file = file, .local = target }, unknown.node, .unknown);
                };
            }
        }

        for (semantic.symbols.getMembers(sym_id).items) |member| {
            const member_id: SymbolId = .{ .file = file, .local = member };
            try graph.addEdge(gpa, .{ .file = file, .local = sym_id }, member_id, semantic.symbols.get(member).decl, .definite);
        }
    }

    return graph;
}
