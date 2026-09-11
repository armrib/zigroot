//! Decl literals: `.init(gpa)`, `.empty`, `.{ ... }`-adjacent `.name`
//! spellings whose container is *not* written at the use site but is
//! syntactically determined by where the literal sits — `var p: Project =
//! .init(gpa);` names `Project.init`, `return .empty;` inside `fn f()
//! Roots` names `Roots.empty`, `flags: Flags = .none` names `Flags.none`.
//!
//! ZLint records no reference for an `.enum_literal` node (there's no
//! identifier to resolve), so without this every `pub const empty: Foo =
//! .{}` / `pub fn init(...) Foo` only ever used through a decl literal is
//! reported dead. Not type inference: the expected type is read off the
//! enclosing declaration's own annotation, exactly as `InstanceType` reads
//! a variable's declared type.
//!
//! This only finds the literal and the type-expression node it must
//! resolve against; `SymbolGraph` resolves that node same-file and
//! `Resolver` across `@import` boundaries, both via the same
//! `container.member` lookup every other chain uses.

const Semantic = @import("semantic/Semantic.zig");
const Ast = Semantic.Ast;
const OwnerMap = @import("OwnerMap.zig");
const InstanceType = @import("InstanceType.zig");

pub const Literal = struct {
    /// The `.enum_literal` node.
    node: Ast.Node.Index,
    /// The member name after the dot.
    name: []const u8,
    /// The type expression the literal is resolved against.
    type_node: Ast.Node.Index,
};

/// If `node` is an `.enum_literal` whose expected type is spelled out on
/// the enclosing declaration — the initializer (possibly called, `.init(
/// ... )`, wrapped in `try`/parens, or one branch of an `if`/`orelse`/
/// `catch`) of a type-annotated `var`/`const`, the value returned from a
/// function with a declared return type, or a container field's default
/// value — that literal with its type node. `null` for every other
/// enum-literal use (a `switch` prong, a struct-init field value, a call
/// argument), whose expected type isn't written down where this can read
/// it.
pub fn at(semantic: *const Semantic, owner_map: *const OwnerMap, node: Ast.Node.Index) ?Literal {
    const ast = &semantic.parse.ast;
    if (ast.nodeTag(node) != .enum_literal) return null;
    const name = semantic.tokenSlice(ast.nodeMainToken(node));

    var child = node;
    var parent = semantic.node_links.getParent(child) orelse return null;

    // `.init(gpa)`: the literal is the callee; the call's own position is
    // what carries the expected type.
    {
        var buf: [1]Ast.Node.Index = undefined;
        if (ast.fullCall(&buf, parent)) |call| {
            if (call.ast.fn_expr != child) return null;
            child = parent;
            parent = semantic.node_links.getParent(child) orelse return null;
        }
    }

    // Wrappers that pass the expected type straight through to the
    // literal.
    while (true) {
        switch (ast.nodeTag(parent)) {
            .grouped_expression, .@"try", .@"orelse", .@"catch", .@"if", .if_simple => {
                child = parent;
                parent = semantic.node_links.getParent(child) orelse return null;
            },
            else => break,
        }
    }

    if (ast.fullVarDecl(parent)) |decl| {
        if (decl.ast.init_node.unwrap() != child) return null;
        const type_node = decl.ast.type_node.unwrap() orelse return null;
        return .{ .node = node, .name = name, .type_node = type_node };
    }

    if (ast.fullContainerField(parent)) |field| {
        if (field.ast.value_expr.unwrap() != child) return null;
        const type_node = field.ast.type_expr.unwrap() orelse return null;
        return .{ .node = node, .name = name, .type_node = type_node };
    }

    if (ast.nodeTag(parent) == .@"return") {
        const owner = owner_map.get(parent) orelse return null;
        if (!semantic.symbols.get(owner).flags.s_fn) return null;
        const type_node = InstanceType.fnReturnTypeNode(semantic, owner) orelse return null;
        return .{ .node = node, .name = name, .type_node = type_node };
    }

    return null;
}
