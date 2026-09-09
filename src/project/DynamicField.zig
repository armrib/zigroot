//! Phase 9: `@field(Container, name)` dynamic field access.
//!
//! `Foo.bar` is an AST `.field_access` node, which `FieldChain` (Phase 7)
//! already walks. `@field(Foo, "bar")` is the same access spelled as a
//! builtin call instead, so `FieldChain` never sees it — this module fills
//! that gap.
//!
//! When the field-name argument is a comptime string literal, the target is
//! just as resolvable as `Foo.bar`; reported at `.possible` confidence
//! rather than `.definite` since it's a separate, less-exercised code path.
//! When the name is a runtime value, no single target can be known
//! statically — every export of the container is a plausible target,
//! reported as `.unknown` edges instead of being silently dropped (the
//! flagship case from the roadmap: "`@field(Foo, name)`, function pointers,
//! dynamic dispatch").
//!
//! Only resolves one `@field` hop directly on a symbol reference; doesn't
//! chain through nested calls, and doesn't cross an `@import` boundary
//! (unlike `FieldChain`/`Resolver`) — out of scope for this pass.

const std = @import("std");
const zlint = @import("zlint");
const Semantic = zlint.Semantic;

pub const Resolution = union(enum) {
    /// Resolved to one specific export, from a comptime-known field name.
    possible: Semantic.Symbol.Id,
    /// Field name isn't statically known; every export of the container is
    /// a plausible target.
    unknown: []const Semantic.Symbol.Id,
};

/// If `node` is the container argument of an `@field(node, name)` builtin
/// call, and `container` (the symbol `node` refers to) has any exports,
/// resolves it. `null` if `node` isn't such a call, or the container has no
/// exports to consider.
pub fn resolve(semantic: *const Semantic, container: Semantic.Symbol.Id, node: Semantic.Ast.Node.Index) ?Resolution {
    const parent = semantic.node_links.getParent(node) orelse return null;
    switch (semantic.parse.ast.nodeTag(parent)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }

    const main_token = semantic.parse.ast.nodeMainToken(parent);
    if (!std.mem.eql(u8, semantic.tokenSlice(main_token), "@field")) return null;

    const pair = semantic.parse.ast.nodeData(parent).opt_node_and_opt_node;
    const base = pair[0].unwrap() orelse return null;
    if (base != node) return null;
    const name_node = pair[1].unwrap() orelse return null;

    const exports = semantic.symbols.getExports(container).items;
    if (exports.len == 0) return null;

    if (semantic.parse.ast.nodeTag(name_node) == .string_literal) {
        const name = std.mem.trim(u8, semantic.tokenSlice(semantic.parse.ast.nodeMainToken(name_node)), "\"");
        for (exports) |id| {
            if (std.mem.eql(u8, semantic.symbols.get(id).name, name)) return .{ .possible = id };
        }
        return null;
    }

    return .{ .unknown = exports };
}
