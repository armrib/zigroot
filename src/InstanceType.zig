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
//! Phase 22: a container field's own type annotation (`foo: Foo` inside a
//! struct/union) is the same shape too, read off a `fullContainerField`
//! instead. `FieldChain.resolveChain` uses this to keep a chain going past a
//! field hop — `h.foo.helper()`, where `foo: Foo` — since `foo`'s own export
//! set is empty (it's a field, not a container); its *declared type* is what
//! has `helper` as an export.
//!
//! Phase 23: an `if (self.meta_log) |*log| ...` optional-payload capture
//! has no type-position node of its own — ZLint gives it only the captured
//! block as its `decl` node. `log`'s type is one level of indirection past
//! what the cases above need: the unwrapped payload of whatever type its
//! `if`'s condition expression (`self.meta_log`) resolves to. `resolve` and
//! `crossFileRoot` both special-case a payload symbol by walking its
//! condition expression through `FieldChain.resolveChain` (reusing the same
//! instance-type-aware hopping `h.foo.bar()` needs) to find the field/
//! variable whose *own* declared type is the optional being unwrapped, then
//! resolving that instead. `resolveTypeExpr`/`fieldAccessRoot` unwrap the
//! leading `?` off whatever type node that turns up.
//!
//! Phase 24: `while (cond) |payload|` is the same shape as an `if`-payload
//! (a `then_expr` decl node, `cond` naming the optional) under a different
//! node tag, so it reuses the same handling. `for (seq) |x|` is a different
//! shape — ZLint gives the `for` node itself as the `decl` node, shared by
//! every capture in `|x, y|` — so its captured sequence is found by
//! matching the capture's identifier token position against `for`'s input
//! list positionally, then resolving *that* input's base symbol the same
//! way. Its element type then falls out of the pointer/array unwrapping
//! `resolveTypeExpr` already does for a `[]T`-typed declaration.
//!
//! ZLint doesn't yet distinguish `self`-taking instance methods from static
//! functions declared in a container (see `Symbol.zig`'s "TODO: bind
//! methods as members") — both land in `Symbol.exports`. So once a
//! variable's declared type resolves to a symbol, `FieldChain.findExport`
//! already finds its instance methods; the only missing piece is that
//! resolution itself.
//!
//! Phase 25: `forElementSource`'s same-file chain-walk comes back empty for
//! a `for (seq) |x|` payload when `seq` is a plain call-init variable (`const
//! tail = tailOf(...);`, no type annotation of its own) — there's no
//! type-position node on `seq` to walk from, since its element type is only
//! known transitively, from whatever function `tailOf` calls to build it.
//! `forElementSequenceSymbol` exposes `seq`'s own base symbol (skipping the
//! chain-walk entirely) so `Resolver.callInstanceType`, which already knows
//! how to resolve a call-init variable's type across `@import` boundaries,
//! can recurse into `seq` itself and reuse that.
//!
//! Phase 28: `const srv = self.srv;` — a variable with no explicit type
//! annotation, initialized from a plain same-file identifier/`.field` chain
//! (not a call, not a struct literal, not an `address_of`) — has no
//! type-position node of its own for `declaredTypeNodes` to find, unlike the
//! `Foo{...}`/`&h.arr[1]` shapes above. `fieldAccessInitSource` walks the
//! initializer's base identifier through `FieldChain.resolveChain` (same as
//! `optionalPayloadSource`) to find the field/variable the chain lands on —
//! here, `ReqCtx.srv` — and `resolve`/`crossFileRoot` recurse into *that*
//! symbol's own declared type (`*Server`) the same way they do for a
//! payload's condition expression. Both hops here are syntactic: `self`'s
//! type comes from Phase 18, `srv`'s from Phase 22 — nothing is inferred
//! from a call return, unlike the `inflight.cont.call(...)` shape (`inflight`
//! from `hashmap.fetchRemove(...).value`) that's still out of scope.
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
const Semantic = @import("semantic/Semantic.zig");
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
    if (optionalPayloadSource(semantic, owner_map, sym_id)) |source| {
        return resolve(semantic, owner_map, source);
    }
    if (forElementSource(semantic, owner_map, sym_id)) |source| {
        return resolve(semantic, owner_map, source);
    }
    if (fieldAccessInitSource(semantic, owner_map, sym_id)) |source| {
        return resolve(semantic, owner_map, source);
    }
    if (addressOfChainTarget(semantic, owner_map, sym_id)) |target| return target;
    if (addressOfChainSource(semantic, owner_map, sym_id)) |source| {
        return resolve(semantic, owner_map, source);
    }
    const candidates = declaredTypeNodes(semantic, sym_id);
    for (candidates.slice()) |type_node| {
        if (resolveTypeExpr(semantic, owner_map, type_node)) |ty| return ty;
    }
    return null;
}

/// Up to two declared-type node candidates, most-specific first.
pub const TypeNodeCandidates = struct {
    nodes: [2]Ast.Node.Index = undefined,
    len: u8 = 0,

    fn push(self: *TypeNodeCandidates, node: Ast.Node.Index) void {
        self.nodes[self.len] = node;
        self.len += 1;
    }

    pub fn slice(self: *const TypeNodeCandidates) []const Ast.Node.Index {
        return self.nodes[0..self.len];
    }
};

/// The declared-type node candidates to try in order for `sym_id`: a
/// function parameter's own type node (`self: *Foo`, one leading pointer
/// unwrapped), a container field's own type annotation (`foo: Foo` inside a
/// struct/union), then an explicit variable type annotation, then an
/// explicitly-typed struct-literal initializer. Empty if `sym_id` is none of
/// these, or has none of these.
pub fn declaredTypeNodes(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) TypeNodeCandidates {
    var out: TypeNodeCandidates = .{};
    const symbol = semantic.symbols.get(sym_id);

    if (symbol.flags.s_fn_param) {
        if (paramTypeNode(semantic, symbol)) |type_node| out.push(type_node);
        return out;
    }

    if (symbol.flags.s_member and !symbol.flags.s_error) {
        if (fieldTypeNode(semantic, symbol)) |type_node| out.push(type_node);
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

/// A container field symbol's own type annotation node (`foo: Foo` ->
/// `Foo`'s node). `null` for a tuple-like field (`struct { a, b }`), which
/// has no type expression of its own to read.
fn fieldTypeNode(semantic: *const Semantic, symbol: *const Semantic.Symbol) ?Ast.Node.Index {
    const ast = &semantic.parse.ast;
    const field = ast.fullContainerField(symbol.decl) orelse return null;
    return field.ast.type_expr.unwrap();
}

/// Resolves a type-position expression node to the symbol it names: a bare
/// identifier (looked up via the `Reference` ZLint already recorded for it,
/// since it's a normal identifier use), a same-file `container.member`
/// chain of those, an optional (`?Foo`, unwrapped to resolve `Foo`), or any
/// pointer/slice (`*Foo`, `*const Foo`, `[]Foo`, `[*]Foo`) or array
/// (`[N]Foo`) wrapper around one of the above, unwrapped to resolve the
/// element/child type.
pub fn resolveTypeExpr(semantic: *const Semantic, owner_map: *const OwnerMap, node: Ast.Node.Index) ?Semantic.Symbol.Id {
    const ast = &semantic.parse.ast;
    if (ast.fullPtrType(node)) |ptr| return resolveTypeExpr(semantic, owner_map, ptr.ast.child_type);
    if (ast.fullArrayType(node)) |array| return resolveTypeExpr(semantic, owner_map, array.ast.elem_type);
    return switch (ast.nodeTag(node)) {
        .identifier => referenceAt(semantic, node),
        .field_access => blk: {
            const data = ast.nodeData(node).node_and_token;
            const base = resolveTypeExpr(semantic, owner_map, data[0]) orelse break :blk null;
            break :blk FieldChain.findExport(semantic, owner_map, base, semantic.tokenSlice(data[1]));
        },
        .optional_type => resolveTypeExpr(semantic, owner_map, ast.nodeData(node).node),
        else => null,
    };
}

/// If `sym_id` is an `if (cond) |payload|` or `while (cond) |payload|`
/// optional-payload capture (not the `else |err|` error-payload case, which
/// `then_expr` matching distinguishes from), the field/variable symbol
/// whose own declared type is the optional being unwrapped — found by
/// walking `cond`'s base identifier through `FieldChain.resolveChain` (the
/// same instance-type-aware hopping `h.foo.bar()` needs, since `cond` is
/// often itself a field chain like `self.meta_log`). `resolve`/
/// `crossFileRoot` recurse into that symbol's own declared type, which
/// `resolveTypeExpr`'s `.optional_type` case then unwraps. `null` for every
/// other payload shape (`for`, `switch`, `catch |err|`) — ZLint gives those
/// a different `decl` node shape, so `thenPayloadCondExpr` on the parent
/// already returns `null` for them.
fn optionalPayloadSource(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_payload) return null;

    const parent = semantic.node_links.getParent(symbol.decl) orelse return null;
    const ast = &semantic.parse.ast;
    const cond_expr = thenPayloadCondExpr(ast, parent, symbol.decl) orelse return null;

    var base_node = cond_expr;
    while (ast.nodeTag(base_node) == .field_access) {
        base_node = ast.nodeData(base_node).node_and_token[0];
    }
    const base_sym = referenceAt(semantic, base_node) orelse return null;

    const chain = FieldChain.resolveChain(semantic, semantic, owner_map, base_sym, base_node, .definite);
    return chain.result.symbol;
}

/// If `parent` is an `if` or `while` node whose `then_expr` is exactly
/// `then_expr` (i.e. `then_expr` is that node's own payload-capturing
/// block, not e.g. an `else |err|` branch), the condition expression being
/// captured. `null` otherwise.
fn thenPayloadCondExpr(ast: *const Ast, parent: Ast.Node.Index, then_expr: Ast.Node.Index) ?Ast.Node.Index {
    if (ast.fullIf(parent)) |if_full| {
        if (if_full.ast.then_expr != then_expr) return null;
        return if_full.ast.cond_expr;
    }
    if (ast.fullWhile(parent)) |while_full| {
        if (while_full.ast.then_expr != then_expr) return null;
        return while_full.ast.cond_expr;
    }
    return null;
}

/// If `sym_id` is a `for (seq) |x|` loop-payload capture — plain or
/// by-reference (`|*x|`), and however many other captures share the same
/// `for` (`for (a, b) |x, y|`) — the field/variable symbol whose own
/// declared type is the sequence being iterated, matched positionally: the
/// capture's identifier token position among the `|...|` list picks out the
/// corresponding `for`-input expression. `resolve`/`crossFileRoot` recurse
/// into that symbol's own declared type, which `resolveTypeExpr`'s pointer/
/// array unwrapping already reduces to the element type — the same
/// unwrapping a `[]T`-typed variable's own declaration needs. Unlike `if`/
/// `while` payloads, ZLint gives a `for`-payload's `decl` node as the `for`
/// node itself (not its `then_expr`), so this checks `ast.fullFor` directly
/// rather than going through a parent lookup. `null` for every other
/// payload shape, or if the matched input isn't a same-file identifier/
/// field-access chain.
const ForElementInput = struct {
    sym: Semantic.Symbol.Id,
    node: Ast.Node.Index,
};

/// If `sym_id` is a `for (seq) |x|` loop-payload capture, the base symbol
/// and node the positionally-matched `for`-input expression's identifier
/// resolves to — the same matching `forElementSource` does, stopping short
/// of walking it any further. `null` for every other payload shape, or if
/// the matched input isn't a same-file identifier/field-access chain.
fn forElementInputBase(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) ?ForElementInput {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_payload) return null;

    const ast = &semantic.parse.ast;
    const for_full = ast.fullFor(symbol.decl) orelse return null;
    const own_token = (symbol.token.unwrap() orelse return null).int();

    var idx: usize = 0;
    var curr = for_full.payload_token;
    while (true) : (curr += 1) {
        switch (ast.tokenTag(curr)) {
            .asterisk, .comma => {},
            .identifier => {
                if (curr == own_token) break;
                idx += 1;
            },
            else => return null,
        }
    }
    if (idx >= for_full.ast.inputs.len) return null;

    var base_node = for_full.ast.inputs[idx];
    while (ast.nodeTag(base_node) == .field_access) {
        base_node = ast.nodeData(base_node).node_and_token[0];
    }
    const base_sym = referenceAt(semantic, base_node) orelse return null;
    return .{ .sym = base_sym, .node = base_node };
}

fn forElementSource(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const base = forElementInputBase(semantic, sym_id) orelse return null;
    const chain = FieldChain.resolveChain(semantic, semantic, owner_map, base.sym, base.node, .definite);
    return chain.result.symbol;
}

/// If `sym_id` is a `for (seq) |x|` loop-payload capture, `seq`'s own base
/// symbol — the bare sequence variable/field itself, with none of
/// `forElementSource`'s forward `.field`/`[]` chain-walking applied. Lets a
/// caller with cross-file, call-return-type resolution `forElementSource`
/// doesn't have (`Resolver.callInstanceType`) try that on the sequence
/// itself when `forElementSource`'s same-file walk comes back empty-handed
/// — e.g. `const tail = tailOf(...); for (tail) |*e| { e.payload(); }`,
/// where `tail`'s element type is only known from `tailOf`'s declared
/// return type, not from any type annotation on `tail` itself.
pub fn forElementSequenceSymbol(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const base = forElementInputBase(semantic, sym_id) orelse return null;
    return base.sym;
}

/// If `sym_id` is a variable with no explicit type annotation, declared as
/// `const c = &expr;` where `expr` is a same-file chain of `.field` and
/// `[index]` hops off an identifier (e.g. `&h.arr[1]`), the symbol that
/// chain resolves to — reusing `FieldChain.resolveChain`'s `array_access`
/// handling so `c` picks up the *element* type an indexed hop lands on,
/// the same way an explicit type annotation would. `null` if `sym_id` isn't
/// such a variable, its initializer isn't an `address_of`, or the chain
/// doesn't resolve same-file (e.g. it's stuck on an `@import` boundary or a
/// runtime-named `@field`).
fn addressOfChainTarget(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const chain = addressOfChainWalk(semantic, owner_map, sym_id) orelse return null;
    if (chain.unknown != null or chain.stuck != null) return null;
    return chain.result.symbol;
}

/// Phase 31: the cross-file half of `addressOfChainTarget`. `var parser =
/// &self.parsers[id];`, where `parsers: []http_mod.Parser`, walks the same
/// chain but gets stuck on the indexed hop, because the element type it
/// would land on lives in another file and `InstanceType` has no `Project`
/// to follow the `@import` with. The symbol it stuck on is the slice field
/// itself, whose own declared type is the `base.field` expression
/// `crossFileRoot` knows how to hand to `Resolver` — so recursing into it
/// resolves the element type the same way an explicit `var parser:
/// *http_mod.Parser` annotation already did. Indexing drops out for free:
/// unwrapping `[]T` to `T` is exactly what the index hop meant.
fn addressOfChainSource(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const chain = addressOfChainWalk(semantic, owner_map, sym_id) orelse return null;
    if (chain.unknown != null) return null;
    const stuck = chain.stuck orelse return null;
    if (stuck.symbol == sym_id) return null;
    return stuck.symbol;
}

/// The shared walk behind `addressOfChainTarget` and `addressOfChainSource`:
/// `sym_id`'s initializer as a chain of `.field`/`[index]` hops off an
/// identifier, resolved as far as one file allows. `null` when `sym_id`
/// isn't an un-annotated variable initialized from `&<chain>`.
fn addressOfChainWalk(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?FieldChain.ChainWalk {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_variable) return null;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    if (decl.ast.type_node.unwrap() != null) return null;

    const init_node = decl.ast.init_node.unwrap() orelse return null;
    if (ast.nodeTag(init_node) != .address_of) return null;
    const expr_node = ast.nodeData(init_node).node;

    var base_node = expr_node;
    while (true) {
        switch (ast.nodeTag(base_node)) {
            .field_access => base_node = ast.nodeData(base_node).node_and_token[0],
            .array_access => base_node = ast.nodeData(base_node).node_and_node[0],
            else => break,
        }
    }
    if (base_node == expr_node) return null;
    const base_sym = referenceAt(semantic, base_node) orelse return null;

    return FieldChain.resolveChain(semantic, semantic, owner_map, base_sym, base_node, .definite);
}

/// If `sym_id` is a variable (`var`/`const`) with no explicit type
/// annotation, declared as `const srv = self.srv;` — a plain same-file
/// identifier or `.field` chain (not a call, not a struct literal, not an
/// `address_of`) — the field/variable symbol that chain resolves to (here,
/// `ReqCtx.srv`), found the same way `optionalPayloadSource` finds the
/// symbol behind an `if`/`while` payload's condition expression: walking the
/// initializer's base identifier through `FieldChain.resolveChain`. `resolve`
/// and `crossFileRoot` recurse into that symbol's own declared type, rather
/// than this returning it directly, since `resolveChain`'s walk only
/// redirects through a field's declared type to look for a *further* hop —
/// with none here, it hands back the field itself. `null` if `sym_id` isn't
/// such a variable, already has an explicit type annotation, or its
/// initializer isn't a same-file identifier/`.field` chain.
fn fieldAccessInitSource(semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?Semantic.Symbol.Id {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_variable) return null;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    if (decl.ast.type_node.unwrap() != null) return null;

    var init_node = decl.ast.init_node.unwrap() orelse return null;
    switch (ast.nodeTag(init_node)) {
        .@"catch", .@"orelse" => init_node = ast.nodeData(init_node).node_and_node[0],
        else => {},
    }
    switch (ast.nodeTag(init_node)) {
        .identifier, .field_access => {},
        else => return null,
    }

    var base_node = init_node;
    while (ast.nodeTag(base_node) == .field_access) {
        base_node = ast.nodeData(base_node).node_and_token[0];
    }
    const base_sym = referenceAt(semantic, base_node) orelse return null;

    const chain = FieldChain.resolveChain(semantic, semantic, owner_map, base_sym, base_node, .definite);
    return chain.result.symbol;
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
    if (optionalPayloadSource(semantic, owner_map, sym_id)) |source| {
        return crossFileRoot(semantic, owner_map, source);
    }
    if (forElementSource(semantic, owner_map, sym_id)) |source| {
        return crossFileRoot(semantic, owner_map, source);
    }
    if (fieldAccessInitSource(semantic, owner_map, sym_id)) |source| {
        return crossFileRoot(semantic, owner_map, source);
    }
    if (addressOfChainSource(semantic, owner_map, sym_id)) |source| {
        return crossFileRoot(semantic, owner_map, source);
    }
    const candidates = declaredTypeNodes(semantic, sym_id);
    for (candidates.slice()) |type_node| {
        if (fieldAccessRoot(semantic, owner_map, type_node)) |root| return root;
    }
    return null;
}

pub fn fieldAccessRoot(semantic: *const Semantic, owner_map: *const OwnerMap, node: Ast.Node.Index) ?CrossFileRoot {
    const ast = &semantic.parse.ast;
    var unwrapped = node;
    while (true) {
        if (ast.fullPtrType(unwrapped)) |ptr| {
            unwrapped = ptr.ast.child_type;
        } else if (ast.fullArrayType(unwrapped)) |array| {
            unwrapped = array.ast.elem_type;
        } else if (ast.nodeTag(unwrapped) == .optional_type) {
            unwrapped = ast.nodeData(unwrapped).node;
        } else break;
    }
    if (ast.nodeTag(unwrapped) != .field_access) return null;
    const data = ast.nodeData(unwrapped).node_and_token;
    const base = resolveTypeExpr(semantic, owner_map, data[0]) orelse return null;
    return .{ .base = base, .field = semantic.tokenSlice(data[1]) };
}

/// If `fn_sym_id` is a function symbol declared in `semantic`, its declared
/// return-type expression node, unwrapped of one leading `!error_union`
/// layer, one leading `?optional_type` layer, and one leading pointer — the
/// same unwrapping `Resolver`'s cross-file call-return-type resolution does
/// for a call-init variable's callee. `null` if `fn_sym_id` isn't a
/// function, or its prototype can't be read.
///
/// Phase 27: shared by `FieldChain.resolveChain`'s same-file handling of a
/// call used directly as a field-access base (`cast(raw).putImpl()`, no
/// intermediate variable to hang a declared type on) — the call-init
/// machinery above needs a variable symbol to key off; this needs only the
/// function symbol being called.
pub fn fnReturnTypeNode(semantic: *const Semantic, fn_sym_id: Semantic.Symbol.Id) ?Ast.Node.Index {
    const symbol = semantic.symbols.get(fn_sym_id);
    if (!symbol.flags.s_fn) return null;

    const ast = &semantic.parse.ast;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&proto_buf, symbol.decl) orelse return null;
    var return_node = proto.ast.return_type.unwrap() orelse return null;
    if (ast.nodeTag(return_node) == .error_union) {
        return_node = ast.nodeData(return_node).node_and_node[1];
    }
    if (ast.nodeTag(return_node) == .optional_type) {
        return_node = ast.nodeData(return_node).node;
    }
    if (ast.fullPtrType(return_node)) |ptr| {
        return_node = ptr.ast.child_type;
    }
    return return_node;
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
/// part of the call expression itself. So is a wrapping `catch`/`orelse`
/// (`var s = Foo.make(id) catch return;` / `Foo.find(id) orelse return`) —
/// both are `node_and_node`, with the wrapped call in `data[0]`.
pub fn callInit(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) ?Ast.Node.Index {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_variable) return null;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    if (decl.ast.type_node.unwrap() != null) return null;

    var init_node = decl.ast.init_node.unwrap() orelse return null;
    switch (ast.nodeTag(init_node)) {
        .@"try" => init_node = ast.nodeData(init_node).node,
        .@"catch", .@"orelse" => init_node = ast.nodeData(init_node).node_and_node[0],
        else => {},
    }

    var buf: [1]Ast.Node.Index = undefined;
    const call = ast.fullCall(&buf, init_node) orelse return null;
    return call.ast.fn_expr;
}

/// Phase 29: `const s = try allocator.create(Foo);` is a different call-init
/// shape than `callInit`/`resolveFnReturnType` handle — `create`'s callee
/// lives in `std.mem.Allocator` (no project-local AST to read a return type
/// off), and the pointee type isn't a return annotation at all, it's spelled
/// out as `Foo` in the call's own argument list. `allocatorCreateTypeArg`
/// reads that argument node directly instead of trying to chase a callee's
/// return type. `null` if `sym_id` isn't such a variable, its initializer
/// isn't a call, the callee isn't a `.create` member-access hop, or the call
/// has no arguments.
pub fn allocatorCreateTypeArg(semantic: *const Semantic, sym_id: Semantic.Symbol.Id) ?Ast.Node.Index {
    const symbol = semantic.symbols.get(sym_id);
    if (!symbol.flags.s_variable) return null;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    if (decl.ast.type_node.unwrap() != null) return null;

    var init_node = decl.ast.init_node.unwrap() orelse return null;
    switch (ast.nodeTag(init_node)) {
        .@"try" => init_node = ast.nodeData(init_node).node,
        .@"catch", .@"orelse" => init_node = ast.nodeData(init_node).node_and_node[0],
        else => {},
    }

    var buf: [1]Ast.Node.Index = undefined;
    const call = ast.fullCall(&buf, init_node) orelse return null;
    if (ast.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const data = ast.nodeData(call.ast.fn_expr).node_and_token;
    if (!std.mem.eql(u8, semantic.tokenSlice(data[1]), "create")) return null;
    if (call.ast.params.len == 0) return null;
    return call.ast.params[0];
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
