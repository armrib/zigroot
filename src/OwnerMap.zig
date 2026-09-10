//! For every AST node in a file, records which declaration (symbol)
//! contains it: the nearest enclosing symbol whose `Symbol.decl` subtree
//! the node falls under.
//!
//! ZLint's `Semantic` already links every visited node to its parent
//! (`NodeLinks.parents`, built once while walking the AST for symbol/scope
//! resolution). `OwnerMap` just walks that parent chain upward from each
//! node until it hits a node that some symbol declares at, rather than
//! re-walking the AST itself.
//!
//! This exists to invert ZLint's `Reference -> Symbol` links into
//! `Symbol -> Symbol` edges (Phase 4's `SymbolGraph`): a reference node's
//! owner is the declaration whose body it textually appears in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");

const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;
const Symbol = Semantic.Symbol;

const OwnerMap = @This();

/// Indexed by `Ast.Node.Index`. `.none` for a node that isn't contained in
/// any declaration (top-level container nodes, the root node itself, and
/// any node ZLint's builder never visited).
owner: []Symbol.Id.Optional,

/// Builds the owner map for one file's `Semantic`. `semantic` must outlive
/// neither the map nor be mutated afterwards; the map only borrows its node
/// count and links, it doesn't hold a reference to it.
pub fn build(gpa: Allocator, semantic: *const Semantic) Allocator.Error!OwnerMap {
    const node_count = semantic.nodes().len;

    // decl node -> declaring symbol. Control-flow payloads (`|x|` in
    // `while`/`for`/`if`/`switch`) are declared with their *body* as the
    // declaration node, not a subtree of their own — the payload isn't what
    // owns everything else in that body, its enclosing declaration is.
    // Registering them here would make every reference inside the body
    // resolve to the payload symbol itself instead of climbing further up,
    // stranding both the payload (a same-symbol self-edge, never reached
    // from a root) and everything referenced inside the body (whose real
    // owner never gets an edge to it). Skip them so the walk below keeps
    // climbing past the payload to the actual enclosing declaration.
    var decl_of: std.AutoHashMapUnmanaged(Ast.Node.Index, Symbol.Id) = .empty;
    defer decl_of.deinit(gpa);
    try decl_of.ensureTotalCapacity(gpa, @intCast(semantic.symbols.symbols.len));

    var sym_it = semantic.symbols.iter();
    while (sym_it.next()) |id| {
        const sym = semantic.symbols.get(id);
        if (sym.flags.s_payload) continue;
        const decl = sym.decl;
        if (decl == Semantic.ROOT_NODE_ID) continue;
        decl_of.putAssumeCapacity(decl, id);
    }

    const owner = try gpa.alloc(Symbol.Id.Optional, node_count);
    errdefer gpa.free(owner);
    @memset(owner, .none);

    for (owner, 0..) |*out, i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        var cur = semantic.node_links.getParent(node);
        while (cur) |c| {
            if (decl_of.get(c)) |sym_id| {
                out.* = Symbol.Id.Optional.from(sym_id);
                break;
            }
            cur = semantic.node_links.getParent(c);
        }
    }

    return .{ .owner = owner };
}

pub fn deinit(self: *OwnerMap, gpa: Allocator) void {
    gpa.free(self.owner);
    self.* = undefined;
}

/// The symbol whose declaration contains `node`, if any.
pub fn get(self: *const OwnerMap, node: Ast.Node.Index) ?Symbol.Id {
    return self.owner[@intFromEnum(node)].unwrap();
}
