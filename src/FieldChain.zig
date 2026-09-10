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
//! Same-file callers pass the same `Semantic` for both. `owner_map` is
//! `symbols`' own `OwnerMap`, used to unwrap a `const Self = @This();`
//! declared inside a nested container (see `findExport`).
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
const InstanceType = @import("InstanceType.zig");
const OwnerMap = @import("OwnerMap.zig");

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

pub const StuckHop = struct {
    /// The symbol (declared in `symbols`) the walk stopped on — a field or
    /// variable whose own declared type is what the next hop needs, but
    /// that type expression crosses an `@import` boundary `InstanceType`
    /// can't follow on its own.
    symbol: Semantic.Symbol.Id,
    node: Semantic.Ast.Node.Index,
    kind: Kind,
};

pub const ChainWalk = struct {
    result: ChainResult,
    /// Set only if the walk stopped at a runtime-named `@field(...)` hop.
    unknown: ?Unknown = null,
    /// Set only if the walk stopped because the next hop's container needs
    /// a cross-file declared-type resolution — see `Resolver`, which has
    /// the `Project` needed to finish it and resume the walk in the target
    /// file.
    stuck: ?StuckHop = null,
};

/// Walks `start` (declared in `symbols`, first referenced at `start_node` in
/// `ast`, already resolved at `start_kind` confidence) through as many
/// `.field` and `@field(...)` hops as resolve to a single export, stopping
/// at the first hop that resolves to nothing or to every export of a
/// container (a runtime-named `@field`, returned via `.unknown` instead of
/// being chased further — it names a set of targets, not one).
pub fn resolveChain(ast: *const Semantic, symbols: *const Semantic, owner_map: *const OwnerMap, start: Semantic.Symbol.Id, start_node: Semantic.Ast.Node.Index, start_kind: Kind) ChainWalk {
    var current: ChainResult = .{ .symbol = start, .node = start_node, .kind = start_kind };
    while (true) {
        // `current.symbol` may itself be a container field or variable
        // rather than a container/type — e.g. after hopping onto `foo` in
        // `h.foo.helper()`, where `foo: Foo` is a field. A field's own
        // export set is empty; it's the type it's declared with that has
        // `helper` as an export. Falls back to `current.symbol` unchanged
        // when it's already a container (the common case), or when it has
        // no syntactically-resolvable declared type. Redirecting through a
        // declared type is the same kind of guess `InstanceType`'s other
        // callers already downgrade to `.possible` for, so every hop after
        // one is used follows suit — `current.kind` only stays `.definite`
        // for a chain of plain static `container.member` hops.
        const type_resolved = InstanceType.resolve(symbols, owner_map, current.symbol);
        const container = type_resolved orelse current.symbol;
        const hop_kind: Kind = if (type_resolved != null) .possible else current.kind;

        if (fieldAccessName(ast, current.node)) |name| {
            if (findExport(symbols, owner_map, container, name)) |next| {
                current = .{ .symbol = next, .node = ast.node_links.getParent(current.node).?, .kind = hop_kind };
                continue;
            }
            if (container == current.symbol and InstanceType.crossFileRoot(symbols, owner_map, current.symbol) != null) {
                return .{ .result = current, .stuck = .{ .symbol = current.symbol, .node = current.node, .kind = .possible } };
            }
            break;
        }

        if (arrayAccessNode(ast, current.node)) |access_node| {
            // Mirrors the `fieldAccessName` stuck-fallback above: an
            // unresolved `type_resolved` means `container` fell back to
            // `current.symbol` itself (the slice/array field, not its
            // element type) — if that field's declared type crosses an
            // `@import` boundary (`conns: []conn_mod.Conn`), hand back to
            // `Resolver` instead of indexing into the field symbol as if it
            // were already the element type. Once `Resolver` resumes the
            // walk with the resolved element type as the new `current.symbol`,
            // `crossFileRoot` has nothing left to find (a container has no
            // declared type of its own), so this falls through to the hop
            // below using it directly, same as the same-file `type_resolved
            // != null` case always has.
            if (type_resolved == null and container == current.symbol) {
                if (InstanceType.crossFileRoot(symbols, owner_map, current.symbol) != null) {
                    return .{ .result = current, .stuck = .{ .symbol = current.symbol, .node = current.node, .kind = .possible } };
                }
            }
            current = .{ .symbol = container, .node = access_node, .kind = hop_kind };
            continue;
        }

        if (DynamicField.resolve(ast, symbols, container, current.node)) |resolution| switch (resolution) {
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

/// If `node` is used as the indexed operand of an array/slice access
/// (`node[i]`), the `array_access` node itself — the element type, once
/// resolved, is already unwrapped onto it so a further `.field` hop off it
/// resolves against the element rather than the array/slice. `null` if
/// `node` isn't an array-access operand.
pub fn arrayAccessNode(ast: *const Semantic, node: Semantic.Ast.Node.Index) ?Semantic.Ast.Node.Index {
    const parent = ast.node_links.getParent(node) orelse return null;
    if (ast.parse.ast.nodeTag(parent) != .array_access) return null;
    const data = ast.parse.ast.nodeData(parent).node_and_node;
    if (data[0] != node) return null;
    return parent;
}

/// Every file's top-level declarations are exported from this symbol.
/// ZLint's `SemanticBuilder.enterRoot` always creates it first, so its id is
/// always 0. Mirrors `Resolver`'s and `Roots`' constant of the same name.
const FILE_ROOT_SYMBOL: Semantic.Symbol.Id = @enumFromInt(0);

/// A symbol directly exported by `container` (ZLint's `Symbol.exports`) or
/// declared as one of its fields (`Symbol.members` — struct/union/enum
/// fields are tracked separately from `const`/`fn` exports), named `name`,
/// if any. `container` is resolved through a `const X = @This();` alias
/// first (see `thisAliasRoot`) — the common `Self`/`<TypeName>` idiom for a
/// container naming itself, which otherwise dead-ends every container
/// lookup that lands on it, since the alias is a plain `const`, not a
/// container, and so has no exports of its own. `owner_map` is `symbols`'
/// own `OwnerMap`, needed to find the true enclosing container of a
/// *nested* such alias.
pub fn findExport(symbols: *const Semantic, owner_map: *const OwnerMap, container: Semantic.Symbol.Id, name: []const u8) ?Semantic.Symbol.Id {
    const resolved = thisAliasRoot(symbols, owner_map, container) orelse container;
    for (symbols.symbols.getExports(resolved).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name)) return id;
    }
    for (symbols.symbols.getMembers(resolved).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name)) return id;
    }
    return null;
}

/// If `container` is a `const X = @This();` alias, the symbol of the
/// container it's declared directly inside (`@This()` names the innermost
/// enclosing container type) — `containerOf(symbols, owner_map, container)`.
/// `null` if `container` isn't such an alias.
fn thisAliasRoot(symbols: *const Semantic, owner_map: *const OwnerMap, container: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
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

    return containerOf(symbols, owner_map, container);
}

/// The container symbol that directly exports `sym_id` — the symbol
/// `OwnerMap` finds containing `sym_id`'s own declaration node, if that
/// owner is itself a struct/enum/union/error set (a nested declaration:
/// `OwnerMap.get` on it lands on some other container symbol, whose own
/// declaration node *is* its container node, which is exactly what a
/// nested declaration's parent chain hits first). For a file-top-level
/// declaration, `OwnerMap` finds no owner (the file root's declaration
/// node is never registered as anyone's containing declaration), so it
/// falls back to checking whether `sym_id` is one of `FILE_ROOT_SYMBOL`'s
/// own exports. `null` if `sym_id`'s owner isn't actually a container
/// (e.g. it's declared inside a function, not a container, directly).
pub fn containerOf(symbols: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const symbol = symbols.symbols.get(sym_id);
    if (owner_map.get(symbol.decl)) |owner| {
        const owner_symbol = symbols.symbols.get(owner);
        return if (owner_symbol.flags.intersects(Semantic.Symbol.Flags.s_container)) owner else null;
    }

    for (symbols.symbols.getExports(FILE_ROOT_SYMBOL).items) |id| {
        if (id == sym_id) return FILE_ROOT_SYMBOL;
    }
    return null;
}
