//! Phase 7: chained field-access resolution (`Foo.bar()`,
//! `Outer.Inner.run()`) through ZLint's `Symbol.exports` — no type
//! inference, just graph traversal over container relationships ZLint
//! already computed.
//!
//! Shared by `SymbolGraph` (same-file) and `Resolver` (cross-file): given a
//! symbol already resolved as the base of a field access, walks as far as
//! possible through nested `container.member` hops, matching each field
//! name against the current symbol's exports. Stops at the first
//! unresolvable hop — an instance value, a name with no matching export, or
//! a use that isn't a field access — since that needs real type inference
//! (`.dynamic_member_call`, Phase 9) rather than a guess.
//!
//! `ast` is the `Semantic` whose AST contains the access nodes (the file
//! doing the referencing). `symbols` is the `Semantic` whose `Symbol.Table`
//! the chain is resolved against; for a cross-file access these differ
//! after the first hop crosses the `@import` boundary, but every hop after
//! that stays within the target file, so one `symbols` suffices per call.
//! Same-file callers pass the same `Semantic` for both.

const std = @import("std");
const zlint = @import("zlint");
const Semantic = zlint.Semantic;

pub const Result = struct {
    symbol: Semantic.Symbol.Id,
    node: Semantic.Ast.Node.Index,
};

/// If `node` is used as the base of a field access (`node.field`), that
/// field's name. `null` if `node` isn't a field-access base.
pub fn fieldAccessName(ast: *const Semantic, node: Semantic.Ast.Node.Index) ?[]const u8 {
    const parent = ast.node_links.getParent(node) orelse return null;
    if (ast.parse.ast.nodeTag(parent) != .field_access) return null;
    const data = ast.parse.ast.nodeData(parent).node_and_token;
    if (data[0] != node) return null;
    return ast.tokenSlice(data[1]);
}

/// A symbol directly exported by `container` (ZLint's `Symbol.exports`)
/// named `name`, if any.
pub fn findExport(symbols: *const Semantic, container: Semantic.Symbol.Id, name: []const u8) ?Semantic.Symbol.Id {
    for (symbols.symbols.getExports(container).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name)) return id;
    }
    return null;
}

/// Walks `start` (declared in `symbols`, first referenced at `start_node`
/// in `ast`) through as many `.field` hops as resolve to an export.
/// Returns `start`/`start_node` unchanged if no hop resolves.
pub fn resolve(ast: *const Semantic, symbols: *const Semantic, start: Semantic.Symbol.Id, start_node: Semantic.Ast.Node.Index) Result {
    var current: Result = .{ .symbol = start, .node = start_node };
    while (fieldAccessName(ast, current.node)) |name| {
        const next = findExport(symbols, current.symbol, name) orelse break;
        current = .{ .symbol = next, .node = ast.node_links.getParent(current.node).? };
    }
    return current;
}
