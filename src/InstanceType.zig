//! Phase 14: instance-method calls on a locally-typed variable
//! (`var s: Foo = ...; s.run();` / `var s = Foo{...}; s.run();`).
//!
//! Not real type inference — still out of scope, per `FieldChain`'s doc
//! comment. This only handles the shapes where a variable's type is spelled
//! out syntactically in its own declaration: an explicit type annotation
//! (`var s: Foo = ...`), or an explicitly-typed struct-literal initializer
//! (`var s = Foo{...}`, as opposed to the anonymous `var s: Foo = .{...}`,
//! which the type-annotation case already covers). A value returned from a
//! call, or otherwise inferred, is still unresolved.
//!
//! Phase 18: a function parameter's declared type (`fn f(self: *Foo) void`)
//! is the same kind of syntactically-spelled-out type, just read off a
//! `fullFnProto` param instead of a `fullVarDecl` — this is the pervasive
//! `self`-receiver shape idiomatic Zig methods use, so it's handled the same
//! way as the variable cases above (one leading pointer is unwrapped, since
//! `self: *Foo` is far more common than a by-value receiver).
//!
//! ZLint doesn't yet distinguish `self`-taking instance methods from static
//! functions declared in a container (see `Symbol.zig`'s "TODO: bind
//! methods as members") — both land in `Symbol.exports`. So once a
//! variable's declared type resolves to a symbol, `FieldChain.findExport`
//! already finds its instance methods; the only missing piece is that
//! resolution itself.
//!
//! `resolve` only resolves a type expression that stays within one file.
//! `crossFileRoot` is the other half, for `Resolver`: when the type
//! expression's root identifier doesn't resolve to anything with the
//! expected field as an export (`storage.Widget`, where `storage` is an
//! `@import` binding rather than a container), it hands back the
//! unresolved `(base, field)` pair so `Resolver` — which has the `Project`
//! needed to tell an `@import` binding from any other symbol, and to reach
//! the target file's exports — can finish the lookup.

const std = @import("std");
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;
const FieldChain = @import("FieldChain.zig");
const OwnerMap = @import("OwnerMap.zig");

/// If `sym_id` is a variable (`var`/`const`) declared with a syntactically
/// resolvable type — an explicit type annotation, or an explicitly-typed
/// struct-literal initializer — or a function parameter with a syntactically
/// resolvable type (optionally behind one leading pointer, e.g. a `self:
/// *Foo` receiver) — the symbol that type expression names. `null` if
/// `sym_id` is neither, has no such type expression, or the type expression
/// isn't a plain identifier / same-file `.field` chain to one (e.g. it's an
/// optional, a generic instantiation, or crosses an `@import` boundary).
pub fn resolve(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const candidates = declaredTypeNodes(semantic, sym_id);
    for (candidates.slice()) |type_node| {
        if (resolveTypeExpr(semantic, owner_map, type_node)) |ty| return ty;
    }
    return null;
}

/// Up to two declared-type node candidates, most-specific first.
const TypeNodeCandidates = struct {
    nodes: [2]Ast.Node.Index = undefined,
    len: u8 = 0,

    fn push(self: *TypeNodeCandidates, node: Ast.Node.Index) void {
        self.nodes[self.len] = node;
        self.len += 1;
    }

    fn slice(self: *const TypeNodeCandidates) []const Ast.Node.Index {
        return self.nodes[0..self.len];
    }
};

/// The declared-type node candidates to try in order for `sym_id`: a
/// function parameter's own type node (`self: *Foo`, one leading pointer
/// unwrapped), then an explicit variable type annotation, then an
/// explicitly-typed struct-literal initializer. Empty if `sym_id` is
/// neither a function parameter nor a variable, or has none of these.
fn declaredTypeNodes(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) TypeNodeCandidates {
    var out: TypeNodeCandidates = .{};
    const symbol = semantic.symbols.get(sym_id);

    if (symbol.flags.s_fn_param) {
        if (paramTypeNode(semantic, symbol)) |type_node| out.push(type_node);
        return out;
    }

    if (!symbol.flags.s_variable) return out;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return out;

    if (decl.ast.type_node.unwrap()) |type_node| out.push(type_node);

    if (decl.ast.init_node.unwrap()) |init_node| {
        var buf: [2]Ast.Node.Index = undefined;
        if (ast.fullStructInit(&buf, init_node)) |struct_init| {
            if (struct_init.ast.type_expr.unwrap()) |type_expr| out.push(type_expr);
        }
    }
    return out;
}

/// A function parameter symbol's declared type node, with one leading
/// pointer unwrapped (`self: *Foo` -> `Foo`'s node, `self: Foo` -> `Foo`'s
/// node unchanged).
fn paramTypeNode(semantic: *const Semantic, symbol: *const Semantic.Symbol) ?Ast.Node.Index {
    const ast = &semantic.parse.ast;
    const node = symbol.decl;
    if (ast.fullPtrType(node)) |ptr| return ptr.ast.child_type;
    return node;
}

/// Resolves a type-position expression node to the symbol it names: a bare
/// identifier (looked up via the `Reference` ZLint already recorded for it,
/// since it's a normal identifier use), or a same-file `container.member`
/// chain of those.
fn resolveTypeExpr(semantic: *const Semantic, owner_map: *const OwnerMap, node: Ast.Node.Index) ?Semantic.Symbol.Id {
    const ast = &semantic.parse.ast;
    return switch (ast.nodeTag(node)) {
        .identifier => referenceAt(semantic, node),
        .field_access => blk: {
            const data = ast.nodeData(node).node_and_token;
            const base = resolveTypeExpr(semantic, owner_map, data[0]) orelse break :blk null;
            break :blk FieldChain.findExport(semantic, owner_map, base, semantic.tokenSlice(data[1]));
        },
        else => null,
    };
}

pub const CrossFileRoot = struct {
    /// The same-file symbol the type expression's root identifier
    /// resolves to — expected to be an `@import` binding, though this
    /// doesn't check that itself (it has no `Project` to check it against).
    base: Semantic.Symbol.Id,
    /// The field name hopped off `base` (`storage.Widget` -> `"Widget"`).
    field: []const u8,
};

/// If `sym_id`'s declared type expression (the same shapes `resolve` looks
/// at: an explicit type annotation or a typed struct-literal initializer)
/// is a `base.field` hop whose `base` resolves same-file (a plain
/// identifier, or a same-file chain of those, e.g. `mod.storage` in
/// `mod.storage.Widget`), that `(base, field)` pair — regardless of
/// whether `base.field` itself resolves same-file. `resolve` already
/// covers the case where it does; this is for a caller (`Resolver`) that
/// can check whether `base` is an `@import` binding and continue the
/// lookup into the target file's exports for the case where it doesn't
/// (`storage.Widget`, `storage` bound to `@import("storage.zig")`).
pub fn crossFileRoot(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?CrossFileRoot {
    const candidates = declaredTypeNodes(semantic, sym_id);
    for (candidates.slice()) |type_node| {
        if (fieldAccessRoot(semantic, owner_map, type_node)) |root| return root;
    }
    return null;
}

fn fieldAccessRoot(semantic: *const Semantic, owner_map: *const OwnerMap, node: Ast.Node.Index) ?CrossFileRoot {
    const ast = &semantic.parse.ast;
    if (ast.nodeTag(node) != .field_access) return null;
    const data = ast.nodeData(node).node_and_token;
    const base = resolveTypeExpr(semantic, owner_map, data[0]) orelse return null;
    return .{ .base = base, .field = semantic.tokenSlice(data[1]) };
}

/// If `sym_id` is a variable with no explicit type annotation, declared
/// with a call expression as its initializer (`var s = Foo.init(...)`),
/// the callee node (`Foo.init`) — a syntax-only extraction, no resolution.
/// Resolving what the callee names, and what its declared return type in
/// turn names, can cross `@import` boundaries more than once (`Semantic
/// .Builder.init(...)`, where `Semantic.Builder` itself re-exports another
/// file's `@import`), which needs a `Project` this module doesn't have —
/// see `Resolver.resolveValueChain`. `null` if `sym_id` isn't a variable,
/// already has an explicit type annotation (`resolve` covers that), or its
/// initializer isn't a call. A leading `try` (`var s = try Foo.init(...)`,
/// the common shape for a fallible `init`) is unwrapped first — it's not
/// part of the call expression itself.
pub fn callInit(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) ?Ast.Node.Index {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_variable) return null;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    if (decl.ast.type_node.unwrap() != null) return null;

    var init_node = decl.ast.init_node.unwrap() orelse return null;
    if (ast.nodeTag(init_node) == .@"try") init_node = ast.nodeData(init_node).node;

    var buf: [1]Ast.Node.Index = undefined;
    const call = ast.fullCall(&buf, init_node) orelse return null;
    return call.ast.fn_expr;
}

/// The symbol the `Reference` recorded at exactly `node` resolves to, if
/// any. ZLint records one `Reference` per identifier use, keyed by that
/// identifier's own node, but doesn't index them by node for lookup — this
/// scans for it directly.
pub fn referenceAt(semantic: *const Semantic, node: Ast.Node.Index) ?Semantic.Symbol.Id {
    const nodes = semantic.symbols.references.items(.node);
    const symbols = semantic.symbols.references.items(.symbol);
    for (nodes, 0..) |ref_node, i| {
        if (ref_node == node) return symbols[i].unwrap();
    }
    return null;
}
