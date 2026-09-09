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
//!
//! Phase 13: `resolveChain` interleaves this with Phase 9's `DynamicField`,
//! so a chain can freely mix static `.field` hops and `@field(...)` hops —
//! `@field(Foo, "Bar").baz()` and `Foo.field("Bar").baz` (via
//! `@field(Foo.field, ...)`-shaped nesting) both resolve as far as they can,
//! instead of `DynamicField` being a dead end after one hop.

const std = @import("std");
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const DynamicField = @import("DynamicField.zig");

/// How confidently a `resolveChain` hop was resolved: `.definite` for a
/// static `.field` hop, `.possible` once a comptime-known `@field(...)` hop
/// has been taken — and every hop after that, since the chain is only as
/// trustworthy as its least-certain link.
pub const Kind = enum { definite, possible };

pub const ChainResult = struct {
    symbol: Semantic.Symbol.Id,
    node: Semantic.Ast.Node.Index,
    kind: Kind,
};

pub const Unknown = struct {
    /// Every export of the container at the point the chain hit a
    /// runtime-named `@field(...)` hop it can't follow further.
    exports: []const Semantic.Symbol.Id,
    node: Semantic.Ast.Node.Index,
};

pub const ChainWalk = struct {
    result: ChainResult,
    /// Set only if the walk stopped at a runtime-named `@field(...)` hop.
    unknown: ?Unknown = null,
};

/// Walks `start` (declared in `symbols`, first referenced at `start_node` in
/// `ast`, already resolved at `start_kind` confidence) through as many
/// `.field` and `@field(...)` hops as resolve to a single export, stopping
/// at the first hop that resolves to nothing or to every export of a
/// container (a runtime-named `@field`, returned via `.unknown` instead of
/// being chased further — it names a set of targets, not one).
pub fn resolveChain(ast: *const Semantic, symbols: *const Semantic, start: Semantic.Symbol.Id, start_node: Semantic.Ast.Node.Index, start_kind: Kind) ChainWalk {
    var current: ChainResult = .{ .symbol = start, .node = start_node, .kind = start_kind };
    while (true) {
        if (fieldAccessName(ast, current.node)) |name| {
            const next = findExport(symbols, current.symbol, name) orelse break;
            current = .{ .symbol = next, .node = ast.node_links.getParent(current.node).?, .kind = current.kind };
            continue;
        }

        if (DynamicField.resolve(ast, symbols, current.symbol, current.node)) |resolution| switch (resolution) {
            .possible => |target| {
                current = .{ .symbol = target, .node = ast.node_links.getParent(current.node).?, .kind = .possible };
                continue;
            },
            .unknown => |exports| return .{
                .result = current,
                .unknown = .{ .exports = exports, .node = ast.node_links.getParent(current.node).? },
            },
        };

        break;
    }
    return .{ .result = current };
}

/// If `node` is used as the base of a field access (`node.field`), that
/// field's name. `null` if `node` isn't a field-access base.
pub fn fieldAccessName(ast: *const Semantic, node: Semantic.Ast.Node.Index) ?[]const u8 {
    const parent = ast.node_links.getParent(node) orelse return null;
    if (ast.parse.ast.nodeTag(parent) != .field_access) return null;
    const data = ast.parse.ast.nodeData(parent).node_and_token;
    if (data[0] != node) return null;
    return ast.tokenSlice(data[1]);
}

/// Every file's top-level declarations are exported from this symbol.
/// ZLint's `SemanticBuilder.enterRoot` always creates it first, so its id is
/// always 0. Mirrors `Resolver`'s and `Roots`' constant of the same name.
const FILE_ROOT_SYMBOL: Semantic.Symbol.Id = @enumFromInt(0);

/// A symbol directly exported by `container` (ZLint's `Symbol.exports`)
/// named `name`, if any. `container` is resolved through a top-level `const
/// X = @This();` alias first (see `thisAliasRoot`) — the common
/// `Self`/`<TypeName>` idiom for a file's own type naming itself, which
/// otherwise dead-ends every container lookup that lands on it, since the
/// alias is a plain `const`, not a container, and so has no exports of its
/// own.
pub fn findExport(symbols: *const Semantic, container: Semantic.Symbol.Id, name: []const u8) ?Semantic.Symbol.Id {
    const resolved = thisAliasRoot(symbols, container) orelse container;
    for (symbols.symbols.getExports(resolved).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name)) return id;
    }
    return null;
}

/// If `container` is a top-level `const X = @This();` alias, the file's own
/// root symbol (`@This()` at file scope names the file's container itself).
/// Checked by asking whether `container` is itself one of `FILE_ROOT_SYMBOL`'s
/// own exports, rather than walking up parents (this module has no
/// `OwnerMap`) — which also means a *nested* `const Self = @This();` inside
/// an inner struct isn't resolved here; only the file-top-level case is.
/// `null` if `container` isn't such an alias.
fn thisAliasRoot(symbols: *const Semantic, container: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const symbol = symbols.symbols.get(container);
    if (!symbol.flags.s_variable) return null;

    const ast = &symbols.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    const init_node = decl.ast.init_node.unwrap() orelse return null;
    switch (ast.nodeTag(init_node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, symbols.tokenSlice(ast.nodeMainToken(init_node)), "@This")) return null;

    for (symbols.symbols.getExports(FILE_ROOT_SYMBOL).items) |id| {
        if (id == container) return FILE_ROOT_SYMBOL;
    }
    return null;
}
