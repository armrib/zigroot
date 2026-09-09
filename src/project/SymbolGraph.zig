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
const Semantic = zlint.Semantic;

const SymbolGraph = @This();

pub const Edge = struct {
    from: SymbolId,
    to: SymbolId,
    node: Semantic.Ast.Node.Index,
};

edges: std.ArrayListUnmanaged(Edge) = .empty,
/// from -> [to, to, ...]
adjacency: std.AutoHashMapUnmanaged(SymbolId, std.ArrayListUnmanaged(SymbolId)) = .empty,

pub const empty: SymbolGraph = .{};

pub fn deinit(self: *SymbolGraph, gpa: Allocator) void {
    self.edges.deinit(gpa);
    var it = self.adjacency.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    self.adjacency.deinit(gpa);
    self.* = undefined;
}

pub fn addEdge(self: *SymbolGraph, gpa: Allocator, from: SymbolId, to: SymbolId, node: Semantic.Ast.Node.Index) !void {
    try self.edges.append(gpa, .{ .from = from, .to = to, .node = node });
    const gop = try self.adjacency.getOrPut(gpa, from);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(gpa, to);
}

/// Symbols directly referenced from `from`'s declaration body. Empty slice
/// if `from` isn't known to reference anything.
pub fn outgoing(self: *const SymbolGraph, from: SymbolId) []const SymbolId {
    if (self.adjacency.get(from)) |list| return list.items;
    return &.{};
}

/// Builds the same-file graph for `file`: for every symbol, every
/// reference to it, mapped through `owner_map` to the declaration the
/// reference occurs in. References with no owner (outside any declaration)
/// are skipped.
///
/// A reference used as the base of a `container.member` chain (Phase 7's
/// `FieldChain`) also gets an edge straight to the innermost resolved
/// export, alongside the direct edge to the container itself — so
/// `Foo.bar()` reaches both `Foo` and `bar`.
pub fn build(gpa: Allocator, file: FileId, semantic: *const Semantic, owner_map: *const OwnerMap) Allocator.Error!SymbolGraph {
    var graph: SymbolGraph = .empty;
    errdefer graph.deinit(gpa);

    var sym_it = semantic.symbols.iter();
    while (sym_it.next()) |sym_id| {
        var ref_it = semantic.symbols.iterReferences(sym_id);
        while (ref_it.next()) |ref| {
            const owner = owner_map.get(ref.node) orelse continue;
            try graph.addEdge(gpa, .{ .file = file, .local = owner }, .{ .file = file, .local = sym_id }, ref.node);

            const chained = FieldChain.resolve(semantic, semantic, sym_id, ref.node);
            if (chained.symbol != sym_id) {
                try graph.addEdge(gpa, .{ .file = file, .local = owner }, .{ .file = file, .local = chained.symbol }, chained.node);
            }
        }
    }

    return graph;
}
