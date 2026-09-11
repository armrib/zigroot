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
const Semantic = @import("semantic/Semantic.zig");

const Ast = Semantic.Ast;
const Symbol = Semantic.Symbol;

const OwnerMap = @This();

/// Indexed by `Ast.Node.Index`. `.none` for a node that isn't contained in
/// any declaration (top-level container nodes, the root node itself, and
/// any node ZLint's builder never visited).
owner: []Symbol.Id.Optional,

/// decl node -> the symbol registered as declared *at* that exact node
/// (see `build`'s `decl_of`). Kept around so callers can tell whether a
/// node is itself somebody's declaration site — needed for an `anytype`
/// parameter, whose `decl` node is the same node its enclosing function
/// was declared at.
self_decl: std.AutoHashMapUnmanaged(Ast.Node.Index, Symbol.Id),

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
    errdefer decl_of.deinit(gpa);
    try decl_of.ensureTotalCapacity(gpa, @intCast(semantic.symbols.symbols.len));

    var sym_it = semantic.symbols.iter();
    while (sym_it.next()) |id| {
        const sym = semantic.symbols.get(id);
        if (sym.flags.s_payload) continue;
        const decl = sym.decl;
        if (decl == Semantic.ROOT_NODE_ID) continue;
        // An `anytype` parameter has no type-expression node, so ZLint
        // declares it at the enclosing `fn_decl` — the same node the
        // function symbol itself was declared at, just before its params
        // were visited. A parameter never owns the function body; letting
        // it claim the node would attribute every reference in the body to
        // the parameter (same self-edge signature as the payload case
        // above). The function is always registered first, so a param
        // whose decl node is already claimed is exactly this case.
        if (sym.flags.s_fn_param and decl_of.contains(decl)) continue;
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

    return .{ .owner = owner, .self_decl = decl_of };
}

pub fn deinit(self: *OwnerMap, gpa: Allocator) void {
    gpa.free(self.owner);
    self.self_decl.deinit(gpa);
    self.* = undefined;
}

/// The symbol whose declaration contains `node`, if any.
pub fn get(self: *const OwnerMap, node: Ast.Node.Index) ?Symbol.Id {
    return self.owner[@intFromEnum(node)].unwrap();
}

/// The symbol registered as declared *at* `node` itself, if any — e.g. for
/// an `anytype` parameter's decl node, this returns its enclosing
/// function's symbol, since that's who claimed the shared node first.
pub fn declaredAt(self: *const OwnerMap, node: Ast.Node.Index) ?Symbol.Id {
    return self.self_decl.get(node);
}
