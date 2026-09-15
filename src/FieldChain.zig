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
const Semantic = @import("semantic/Semantic.zig");
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

/// Phase 27: mirrors `StuckHop`, for a call used directly as a field-access
/// base (`cast(raw).putImpl()`) whose callee's declared return type crosses
/// an `@import` boundary `InstanceType.fnReturnTypeNode` can't follow on its
/// own.
pub const StuckCall = struct {
    /// The function symbol (declared in `symbols`) that was called.
    fn_symbol: Semantic.Symbol.Id,
    /// The call node itself — becomes the resumed walk's node once the
    /// return type resolves, so a further `.field` hop off it resolves
    /// against the return type.
    call_node: Semantic.Ast.Node.Index,
    kind: Kind,
};

/// Phase 30: mirrors `StuckHop`, for a hop off a plain value alias —
/// `const Project = zigroot.Project;`, `const FileId =
/// @import("FileId.zig").FileId;`, `const Self = Outer.Inner;` — a `const`
/// whose initializer is an identifier, a `.field` chain, or an `@import`
/// call (optionally field-accessed). Such a binding has no exports of its
/// own; what it *names* does, and naming it may cross any number of
/// `@import` boundaries, which only `Resolver` can follow.
pub const StuckAlias = struct {
    /// The alias symbol (declared in `symbols`) the walk stopped on.
    symbol: Semantic.Symbol.Id,
    node: Semantic.Ast.Node.Index,
    kind: Kind,
};

/// Upper bound on the intermediate hops one `resolveChain` segment
/// records in `ChainWalk.visited`; longer chains still resolve, only the
/// hops past this many go unrecorded.
pub const max_visited = 16;

pub const ChainWalk = struct {
    result: ChainResult,
    /// Every symbol the walk passed *through* between `start` and
    /// `result` (exclusive of both), in order — `Inner` in
    /// `Outer.Inner.run()`, `symbol` in `project.symbol(id).name`. Each is
    /// as used as the final target is, so callers edge them all.
    visited: [max_visited]Semantic.Symbol.Id = undefined,
    visited_len: usize = 0,
    /// Set only if the walk stopped at a runtime-named `@field(...)` hop.
    unknown: ?Unknown = null,
    /// Set only if the walk stopped because the next hop's container needs
    /// a cross-file declared-type resolution — see `Resolver`, which has
    /// the `Project` needed to finish it and resume the walk in the target
    /// file.
    stuck: ?StuckHop = null,
    /// Set only if the walk stopped because a call's own declared return
    /// type needs a cross-file resolution — see `Resolver`, mirroring
    /// `stuck` above.
    stuck_call: ?StuckCall = null,
    /// Set only if the walk stopped on a value alias whose target may lie
    /// in another file — see `Resolver`, mirroring `stuck` above.
    stuck_alias: ?StuckAlias = null,

    pub fn visitedSlice(walk: *const ChainWalk) []const Semantic.Symbol.Id {
        return walk.visited[0..walk.visited_len];
    }
};

/// Walks `start` (declared in `symbols`, first referenced at `start_node` in
/// `ast`, already resolved at `start_kind` confidence) through as many
/// `.field` and `@field(...)` hops as resolve to a single export, stopping
/// at the first hop that resolves to nothing or to every export of a
/// container (a runtime-named `@field`, returned via `.unknown` instead of
/// being chased further — it names a set of targets, not one).
pub fn resolveChain(ast: *const Semantic, symbols: *const Semantic, owner_map: *const OwnerMap, start: Semantic.Symbol.Id, start_node: Semantic.Ast.Node.Index, start_kind: Kind) ChainWalk {
    var walk: ChainWalk = .{ .result = .{ .symbol = start, .node = start_node, .kind = start_kind } };
    walk.result = resolveChainInner(ast, symbols, owner_map, &walk);
    return walk;
}

/// Records `current` as passed through, once the walk moves on from it.
fn visit(walk: *ChainWalk, current: ChainResult, start: Semantic.Symbol.Id) void {
    if (current.symbol == start) return;
    if (walk.visited_len >= max_visited) return;
    walk.visited[walk.visited_len] = current.symbol;
    walk.visited_len += 1;
}

fn resolveChainInner(ast: *const Semantic, symbols: *const Semantic, owner_map: *const OwnerMap, walk: *ChainWalk) ChainResult {
    const start = walk.result.symbol;
    var current = walk.result;
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
                visit(walk, current, start);
                current = .{ .symbol = next, .node = ast.node_links.getParent(current.node).?, .kind = hop_kind };
                continue;
            }
            if (container == current.symbol and hasUnresolvedDeclaredType(symbols, owner_map, current.symbol)) {
                walk.stuck = .{ .symbol = current.symbol, .node = current.node, .kind = .possible };
                return current;
            }
            // Phase 30: the container this hop needs is a value alias —
            // either `current.symbol` itself (`Project.init`, `Project`
            // being `const Project = zigroot.Project`) or the declared
            // type it resolved to (`self.import_graph.deinit()`, where
            // `import_graph: ImportGraph` and `ImportGraph` is an `@import`
            // binding). `Resolver` finishes it either way.
            if (valueAliasInit(symbols, container, .{ .allow_call = true }) != null) {
                if (container != current.symbol) visit(walk, current, start);
                walk.stuck_alias = .{ .symbol = container, .node = current.node, .kind = hop_kind };
                return current;
            }
            break;
        }

        // An `.?` is pure unwrapping, not a hop onto a new symbol: the
        // payload type is `current.symbol`'s own declared type minus its
        // leading `?`, which `InstanceType` strips anyway. Stepping the node
        // over it lets the `.field` hop after it resolve against the same
        // container, instead of the walk ending on the unwrap.
        if (optionalUnwrapNode(ast, current.node)) |unwrap_node| {
            current = .{ .symbol = current.symbol, .node = unwrap_node, .kind = current.kind };
            continue;
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
                if (hasUnresolvedDeclaredType(symbols, owner_map, current.symbol)) {
                    walk.stuck = .{ .symbol = current.symbol, .node = current.node, .kind = .possible };
                    return current;
                }
            }
            if (container != current.symbol) visit(walk, current, start);
            current = .{ .symbol = container, .node = access_node, .kind = hop_kind };
            continue;
        }

        // Phase 27: `cast(raw).putImpl()` — `current.node` (`cast`) is used
        // directly as a call's callee, and the call's result is itself
        // field-accessed, with no intermediate variable to hang a declared
        // type on. If `container` (the callee) is a function, its declared
        // return type continues the chain the same way a field's declared
        // type does above.
        if (callAccessNode(ast, current.node)) |call_node| {
            if (symbols.symbols.get(container).flags.s_fn) {
                if (InstanceType.fnReturnTypeNode(symbols, container)) |return_node| {
                    if (InstanceType.resolveTypeExpr(symbols, owner_map, return_node)) |ret_sym| {
                        visit(walk, current, start);
                        current = .{ .symbol = ret_sym, .node = call_node, .kind = .possible };
                        continue;
                    }
                    // A return type that's a `.field` chain into another
                    // file, or a bare alias/`@import` binding (`*const
                    // File`, `File` being `@import("File.zig")`): either
                    // way `Resolver` resolves the return type and resumes.
                    if (InstanceType.fieldAccessRoot(symbols, owner_map, return_node) != null or returnTypeIsAlias(symbols, owner_map, return_node)) {
                        walk.stuck_call = .{ .fn_symbol = container, .call_node = call_node, .kind = .possible };
                        return current;
                    }
                }
            }
        }

        if (DynamicField.resolve(ast, symbols, container, current.node)) |resolution| switch (resolution) {
            .possible => |target| {
                visit(walk, current, start);
                current = .{ .symbol = target, .node = ast.node_links.getParent(current.node).?, .kind = .possible };
                continue;
            },
            .unknown => |exports| {
                walk.unknown = .{ .exports = exports, .node = ast.node_links.getParent(current.node).? };
                return current;
            },
        };

        break;
    }
    return current;
}

/// Whether `sym_id` has a declared type written down at all
/// (`InstanceType.declaredTypeNodes`) — given the caller already found it
/// doesn't resolve same-file, that means the type expression crosses an
/// `@import` boundary or goes through an alias, which only `Resolver` can
/// follow (Phase 30 generalizes the earlier `crossFileRoot`-only check:
/// `owner: []Symbol.Id.Optional` with `Symbol` an alias is stuck too).
fn hasUnresolvedDeclaredType(symbols: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) bool {
    if (InstanceType.crossFileRoot(symbols, owner_map, sym_id) != null) return true;
    return InstanceType.declaredTypeNodes(symbols, sym_id).slice().len > 0;
}

/// Whether `return_node` (already known not to resolve same-file to a
/// container) names, after the usual pointer/optional unwrapping, a value
/// alias — so the callee's return type is only resolvable via `Resolver`.
fn returnTypeIsAlias(symbols: *const Semantic, owner_map: *const OwnerMap, return_node: Semantic.Ast.Node.Index) bool {
    const ty = InstanceType.resolveTypeExpr(symbols, owner_map, return_node) orelse return false;
    return valueAliasInit(symbols, ty, .{ .allow_call = true }) != null;
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
/// If `node` is the operand of an `.?` optional unwrap (`node.?`), the
/// unwrap node itself. The payload's type is whatever `node`'s own declared
/// type is once the leading `?` comes off, which `InstanceType`'s type-expr
/// unwrapping already does — so a chain only has to step over the `.?` to
/// keep hopping (`self.spoa.?.onRecv()`). `null` if `node` isn't unwrapped.
pub fn optionalUnwrapNode(ast: *const Semantic, node: Semantic.Ast.Node.Index) ?Semantic.Ast.Node.Index {
    const parent = ast.node_links.getParent(node) orelse return null;
    if (ast.parse.ast.nodeTag(parent) != .unwrap_optional) return null;
    if (ast.parse.ast.nodeData(parent).node_and_token[0] != node) return null;
    return parent;
}

pub fn arrayAccessNode(ast: *const Semantic, node: Semantic.Ast.Node.Index) ?Semantic.Ast.Node.Index {
    const parent = ast.node_links.getParent(node) orelse return null;
    if (ast.parse.ast.nodeTag(parent) != .array_access) return null;
    const data = ast.parse.ast.nodeData(parent).node_and_node;
    if (data[0] != node) return null;
    return parent;
}

/// If `node` is used as the callee of a call expression (`node(args)`) whose
/// result is immediately field-accessed (`node(args).field`), the call node
/// itself — the callee's return type, once resolved, is unwrapped onto it so
/// a further `.field` hop off it resolves against the return type instead of
/// the callee itself. `null` if `node` isn't a call callee (e.g. it's a call
/// argument instead), or the call's result isn't field-accessed.
pub fn callAccessNode(ast: *const Semantic, node: Semantic.Ast.Node.Index) ?Semantic.Ast.Node.Index {
    const parent = ast.node_links.getParent(node) orelse return null;
    var buf: [1]Semantic.Ast.Node.Index = undefined;
    const call = ast.parse.ast.fullCall(&buf, parent) orelse return null;
    if (call.ast.fn_expr != node) return null;

    const grandparent = ast.node_links.getParent(parent) orelse return null;
    if (ast.parse.ast.nodeTag(grandparent) != .field_access) return null;
    const data = ast.parse.ast.nodeData(grandparent).node_and_token;
    if (data[0] != parent) return null;
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
///
/// ZLint's `Symbol.exports` for a container isn't limited to the
/// container's own top-level declarations — it also includes any
/// `const`/`var` locals declared inside the container's method bodies. An
/// `exports` candidate is only accepted if `isContainerMember` confirms its
/// declaration site is textually a member of some container (struct, union,
/// enum, or the file root — which every top-level declaration is a member
/// of), rather than a statement inside a function body. A method-local's
/// nearest enclosing structural node is that function's `block`, not a
/// container, so it's rejected and the search falls through to `members`
/// (or `null`) instead of shadowing a real field of the same name. This
/// stays true even for a method nested inside a further-nested *anonymous*
/// container with no symbol of its own — e.g. a `type`-returning function's
/// `return struct { pub fn init() ... };` — since the check only cares
/// whether the nearest structural ancestor is a container, not which named
/// symbol (if any) owns it.
pub fn findExport(symbols: *const Semantic, owner_map: *const OwnerMap, container: Semantic.Symbol.Id, name: []const u8) ?Semantic.Symbol.Id {
    const resolved = thisAliasRoot(symbols, owner_map, container) orelse container;
    for (symbols.symbols.getExports(resolved).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name) and isContainerMember(symbols, symbols.symbols.get(id).decl)) return id;
    }
    for (symbols.symbols.getMembers(resolved).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name)) return id;
    }
    return null;
}

/// Whether `decl` is textually declared as a direct member of a container
/// (struct/union/enum literal, tagged or not, or the file root) rather than
/// as a statement inside a function body — found by climbing `decl`'s AST
/// parent chain and checking which kind of enclosing node is hit first.
fn isContainerMember(symbols: *const Semantic, decl: Semantic.Ast.Node.Index) bool {
    const ast = &symbols.parse.ast;
    var cur = symbols.node_links.getParent(decl);
    while (cur) |c| {
        switch (ast.nodeTag(c)) {
            .root,
            .container_decl,
            .container_decl_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => return true,
            .block, .block_semicolon, .block_two, .block_two_semicolon => return false,
            else => cur = symbols.node_links.getParent(c),
        }
    }
    return false;
}

pub const ValueChainOptions = struct {
    /// Also accept a call (`util.Bitflags(Flags)`, `project.file(id)`) at
    /// any point of the chain: the value is then whatever the callee's
    /// declared return type names. Off for callers that only want a
    /// *renaming* (`const Project = zigroot.Project`), not a computed
    /// value.
    allow_call: bool = false,
};

/// If `sym_id` is a plain value alias — a `const`/`var` whose initializer
/// is a bare identifier, a `.field` chain, or an `@import(...)` call
/// (optionally field-accessed: `@import("x.zig").Y`), possibly wrapped in
/// `&`/`try`/parens — that initializer node. With `allow_call`, a call
/// anywhere in the chain is accepted too. `null` for a container
/// declaration, a function, a parameter, a field, or a variable
/// initialized any other way (a literal, `@This()`).
pub fn valueAliasInit(symbols: *const Semantic, sym_id: Semantic.Symbol.Id, options: ValueChainOptions) ?Semantic.Ast.Node.Index {
    const symbol = symbols.symbols.get(sym_id);
    if (!symbol.flags.s_variable or symbol.flags.s_fn_param or symbol.flags.s_member or symbol.flags.s_payload) return null;
    if (symbol.flags.intersects(Semantic.Symbol.Flags.s_container)) return null;

    const ast = &symbols.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    const init_node = decl.ast.init_node.unwrap() orelse return null;
    return if (isValueChain(symbols, init_node, options)) init_node else null;
}

/// Whether `node` is an identifier, a `.field` chain, or an `@import(...)`
/// call, with any number of `.field` hops off any of those, optionally
/// wrapped in `&`, `try`, parens, `.*` or `.?`; with `allow_call`, calls
/// too.
pub fn isValueChain(symbols: *const Semantic, node: Semantic.Ast.Node.Index, options: ValueChainOptions) bool {
    const ast = &symbols.parse.ast;
    return switch (ast.nodeTag(node)) {
        .identifier => true,
        .field_access => isValueChain(symbols, ast.nodeData(node).node_and_token[0], options),
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, symbols.tokenSlice(ast.nodeMainToken(node)), "@import"),
        .address_of, .@"try", .deref => isValueChain(symbols, ast.nodeData(node).node, options),
        .grouped_expression, .unwrap_optional => isValueChain(symbols, ast.nodeData(node).node_and_token[0], options),
        .call, .call_comma, .call_one, .call_one_comma => blk: {
            if (!options.allow_call) break :blk false;
            var buf: [1]Semantic.Ast.Node.Index = undefined;
            const call = ast.fullCall(&buf, node) orelse break :blk false;
            break :blk isValueChain(symbols, call.ast.fn_expr, options);
        },
        else => false,
    };
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
