//! Phase 14: instance-method calls on a locally-typed variable
//! (`var s: Foo = ...; s.run();` / `var s = Foo{...}; s.run();`).
//!
//! Not real type inference — still out of scope, per `FieldChain`'s doc
//! comment. This only handles the two shapes where a variable's type is
//! spelled out syntactically in its own declaration: an explicit type
//! annotation (`var s: Foo = ...`), or an explicitly-typed struct-literal
//! initializer (`var s = Foo{...}`, as opposed to the anonymous `var s: Foo
//! = .{...}`, which the type-annotation case already covers). A value
//! passed as a function parameter, returned from a call, or otherwise
//! inferred is still unresolved.
//!
//! ZLint doesn't yet distinguish `self`-taking instance methods from static
//! functions declared in a container (see `Symbol.zig`'s "TODO: bind
//! methods as members") — both land in `Symbol.exports`. So once a
//! variable's declared type resolves to a symbol, `FieldChain.findExport`
//! already finds its instance methods; the only missing piece is that
//! resolution itself.

const std = @import("std");
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;
const FieldChain = @import("FieldChain.zig");

/// If `sym_id` is a variable (`var`/`const`) declared with a syntactically
/// resolvable type — an explicit type annotation, or an explicitly-typed
/// struct-literal initializer — the symbol that type expression names.
/// `null` if `sym_id` isn't a variable, has no such type expression, or the
/// type expression isn't a plain identifier / same-file `.field` chain to
/// one (e.g. it's a pointer type, an optional, a generic instantiation, or
/// crosses an `@import` boundary).
pub fn resolve(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_variable) return null;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;

    if (decl.ast.type_node.unwrap()) |type_node| {
        if (resolveTypeExpr(semantic, type_node)) |ty| return ty;
    }

    const init_node = decl.ast.init_node.unwrap() orelse return null;
    var buf: [2]Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, init_node) orelse return null;
    const type_expr = struct_init.ast.type_expr.unwrap() orelse return null;
    return resolveTypeExpr(semantic, type_expr);
}

/// Resolves a type-position expression node to the symbol it names: a bare
/// identifier (looked up via the `Reference` ZLint already recorded for it,
/// since it's a normal identifier use), or a same-file `container.member`
/// chain of those.
fn resolveTypeExpr(semantic: *const Semantic, node: Ast.Node.Index) ?Semantic.Symbol.Id {
    const ast = &semantic.parse.ast;
    return switch (ast.nodeTag(node)) {
        .identifier => referenceAt(semantic, node),
        .field_access => blk: {
            const data = ast.nodeData(node).node_and_token;
            const base = resolveTypeExpr(semantic, data[0]) orelse break :blk null;
            break :blk FieldChain.findExport(semantic, base, semantic.tokenSlice(data[1]));
        },
        else => null,
    };
}

/// The symbol the `Reference` recorded at exactly `node` resolves to, if
/// any. ZLint records one `Reference` per identifier use, keyed by that
/// identifier's own node, but doesn't index them by node for lookup — this
/// scans for it directly.
fn referenceAt(semantic: *const Semantic, node: Ast.Node.Index) ?Semantic.Symbol.Id {
    const nodes = semantic.symbols.references.items(.node);
    const symbols = semantic.symbols.references.items(.symbol);
    for (nodes, 0..) |ref_node, i| {
        if (ref_node == node) return symbols[i].unwrap();
    }
    return null;
}
