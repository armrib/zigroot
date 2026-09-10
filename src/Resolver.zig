//! Phase 6: cross-file `Symbol -> Symbol` edges through `@import`.
//!
//! `SymbolGraph` (Phase 4) only sees references within one file. This fills
//! in the other half: `const storage = @import("storage.zig");
//! storage.start();` binds `storage` to a symbol whose declaration node
//! *is* the `@import(...)` call — found the same way `OwnerMap` finds any
//! declaration containing a node. A reference to that binding used as the
//! base of a field access (`storage.start`) is then matched by name against
//! the target file's exported symbols (ZLint's `Symbol.exports`, on the
//! implicit file-root symbol every top-level declaration is exported from).
//!
//! After that first hop, Phase 7's `FieldChain` continues resolving further
//! `container.member` hops entirely within the target file (e.g.
//! `storage.Inner.run()`), so static-member access chains through an
//! `@import` boundary too.
//!
//! Phase 12: a reference to the binding used as the container argument of
//! `@field(storage, name)` is resolved the same way, via `DynamicField`
//! against the target file's exports — a comptime-known name at `.possible`
//! confidence, a runtime name as `.unknown` edges to every export.
//!
//! Phase 13: whichever hop crosses the `@import` boundary (a plain
//! `storage.start` or a comptime-known `@field(storage, "start")`), further
//! hops within the target file use `FieldChain.resolveChain`, so `.field`
//! and `@field(...)` hops keep interleaving past the boundary too —
//! `storage.field("Bar").baz` or `@field(storage, "Inner").run()` chain as
//! far as they resolve, same as the same-file case in `SymbolGraph`.
//!
//! Phase 15: `InstanceType`'s same-file variable-type resolution
//! (`var s: Foo = ...; s.run();`) gets the same cross-file treatment —
//! `var s: storage.Widget = ...; s.run();` resolves `storage.Widget` into
//! the target file's exports the same way `storage.start()` does above,
//! then chains `s`'s own references the same way `FieldChain` does for the
//! same-file case.
//!
//! Phase 17: `var s = Foo.init(...); s.run();` — Zig requires a function's
//! return type to be spelled out, so it's as legitimate a "type written
//! down" as `InstanceType`'s other two shapes (an annotation, a typed
//! struct-literal initializer); the missing piece is resolving what the
//! callee (`Foo.init`) and its return-type expression actually name.
//! `resolveValueChain` does that: unlike `FieldChain`/`InstanceType`, which
//! stay within one file or cross exactly one `@import` boundary, it keeps
//! hopping across as many as the expression does — needed since a resolved
//! hop can itself be bound to another `@import` (a re-export, e.g. `pub
//! const Builder = @import("Builder.zig")` inside a file already crossed
//! into). A `const Self = @This();` (or any name) alias — the plain
//! `const` a container names itself with, which otherwise has no exports
//! of its own to match a further hop against — is handled by
//! `FieldChain.findExport` itself, so every hop through this walk gets it
//! for free.
//!
//! Phase 20: `const Schema = @import("json.zig").Schema;` binds to one
//! export of the target file, not the whole file, right at the
//! `@import(...)` call — `aliasRoot` detects this and resolves every
//! reference to the binding (further field hops and bare uses alike)
//! against that export instead of the target file's root.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;

const Project = @import("Project.zig");
const ImportGraph = @import("ImportGraph.zig");
const FileId = @import("FileId.zig").FileId;
const SymbolId = @import("SymbolId.zig").SymbolId;
const SymbolGraph = @import("SymbolGraph.zig");
const FieldChain = @import("FieldChain.zig");
const DynamicField = @import("DynamicField.zig");
const InstanceType = @import("InstanceType.zig");
const OwnerMap = @import("OwnerMap.zig");

/// Every file's top-level declarations are exported from this symbol.
/// ZLint's `SemanticBuilder.enterRoot` always creates it first, so its id is
/// always 0.
const FILE_ROOT_SYMBOL: Semantic.Symbol.Id = @enumFromInt(0);

/// Builds cross-file edges for every resolved `@import("file.zig")` binding
/// in `project`: for each reference to the binding used as a field-access
/// base, an edge from the referencing declaration to the target file's
/// same-named export, if one exists.
pub fn build(gpa: Allocator, project: *const Project) Allocator.Error!SymbolGraph {
    var graph: SymbolGraph = .empty;
    errdefer graph.deinit(gpa);

    for (project.import_graph.edges.items) |import_edge| {
        const from_file = project.file(import_edge.from);
        const binding = from_file.owner_map.get(import_edge.node) orelse continue;
        const target_file = project.file(import_edge.to);
        const target_semantic = &target_file.semantic;

        // `const Schema = @import("json.zig").Schema;` narrows the binding
        // to one export of the target file right at the `@import(...)`
        // call itself, rather than the whole file root — see `aliasRoot`.
        const import_root = aliasRoot(&from_file.semantic, import_edge.node, target_semantic, &target_file.owner_map) orelse FILE_ROOT_SYMBOL;

        var ref_it = from_file.semantic.symbols.iterReferences(binding);
        while (ref_it.next()) |ref| {
            const owner = from_file.owner_map.get(ref.node) orelse continue;
            const owner_id: SymbolId = .{ .file = import_edge.from, .local = owner };

            if (FieldChain.fieldAccessName(&from_file.semantic, ref.node)) |field_name| {
                const target_local = FieldChain.findExport(target_semantic, &target_file.owner_map, import_root, field_name) orelse continue;
                const field_node = from_file.semantic.node_links.getParent(ref.node).?;
                try addChain(project, &graph, gpa, owner_id, import_edge.to, &from_file.semantic, target_semantic, &target_file.owner_map, target_local, field_node, .definite);
                continue;
            }

            if (DynamicField.resolve(&from_file.semantic, target_semantic, import_root, ref.node)) |resolution| {
                switch (resolution) {
                    .possible => |target| {
                        const field_node = from_file.semantic.node_links.getParent(ref.node).?;
                        try addChain(project, &graph, gpa, owner_id, import_edge.to, &from_file.semantic, target_semantic, &target_file.owner_map, target, field_node, .possible);
                    },
                    .unknown => |exports| for (exports) |target| {
                        try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = target }, ref.node, .unknown);
                    },
                }
                continue;
            }

            // A bare reference to an alias binding narrowed by `import_root`
            // above (e.g. `Schema{...}`, `fn f() Schema`) — nothing further
            // to chase, but the aliased declaration itself is what needs to
            // be reachable, not just its own further field hops.
            if (import_root != FILE_ROOT_SYMBOL) {
                try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = import_root }, ref.node, .definite);
            }
        }
    }

    try buildInstanceTypes(gpa, &graph, project);
    try buildCallInstanceTypes(gpa, &graph, project);
    try buildStuckFieldChains(gpa, &graph, project);

    return graph;
}

/// Phase 22: `SymbolGraph.build` walks every same-file reference through
/// `FieldChain.resolveChain` itself (both the reference's own chain and, for
/// an instance-typed variable, the chain from its type), but has no
/// `Project` to finish a chain that gets stuck on a field/variable whose own
/// declared type crosses an `@import` boundary (`h.foo.bar()`, where `foo`'s
/// type is `mod.Foo`) — see `FieldChain.ChainWalk.stuck`. Mirrors that same
/// reference-walking structure, but only to find the chains that got stuck,
/// and finishes them via `addChain`'s cross-file continuation. Chains that
/// resolved without needing this are already edged by `SymbolGraph.build`;
/// redoing them here too is harmless (graphs tolerate duplicate edges).
fn buildStuckFieldChains(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            const instance_ty = InstanceType.resolve(semantic, &file.owner_map, sym_id);

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = file.owner_map.get(ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };

                const chain = FieldChain.resolveChain(semantic, semantic, &file.owner_map, sym_id, ref.node, .definite);
                if (chain.stuck != null) {
                    try addChain(project, graph, gpa, owner_id, file.id, semantic, semantic, &file.owner_map, sym_id, ref.node, .definite);
                }

                if (instance_ty) |ty| {
                    const inst_chain = FieldChain.resolveChain(semantic, semantic, &file.owner_map, ty, ref.node, .possible);
                    if (inst_chain.stuck != null) {
                        try addChain(project, graph, gpa, owner_id, file.id, semantic, semantic, &file.owner_map, ty, ref.node, .possible);
                    }
                }
            }
        }
    }
}

/// Phase 20: if `import_node` (the `@import(...)` call itself) is
/// immediately field-accessed (`@import("json.zig").Schema`, as opposed to
/// a whole-module binding like `@import("storage.zig")`), the symbol that
/// field names in the target file — `null` if `import_node` isn't
/// field-accessed this way, or the field doesn't match one of the target
/// file's exports. A binding declared this way (`const Schema =
/// @import("json.zig").Schema;`) is narrowed to that one export before it's
/// ever named locally, so every reference to the binding — whether a
/// further field hop (`Schema.Context`) or a bare use (`Schema{...}`, `fn
/// f() Schema`) — needs to resolve against *this* symbol instead of the
/// target file's root, which is what `build`'s main loop otherwise assumes
/// every binding represents.
fn aliasRoot(from_semantic: *const Semantic, import_node: Semantic.Ast.Node.Index, target_semantic: *const Semantic, target_owner_map: *const OwnerMap) ?Semantic.Symbol.Id {
    const field_name = FieldChain.fieldAccessName(from_semantic, import_node) orelse return null;
    return FieldChain.findExport(target_semantic, target_owner_map, FILE_ROOT_SYMBOL, field_name);
}

/// Phase 15: `var s: storage.Widget = ...; s.run();`, where `storage` is an
/// `@import` binding — `InstanceType.resolve` only resolves a type
/// expression that stays within one file, so `s`'s declared type
/// (`storage.Widget`) is invisible to it. For every variable that's true
/// of, `InstanceType.crossFileRoot` hands back the unresolved `(base,
/// field)` pair; `importTarget` checks whether `base` really is one of this
/// file's `@import` bindings (same "nearest enclosing declaration of the
/// `@import(...)` call" trick the main loop above uses), and if so,
/// `FieldChain.findExport` matches `field` against the target file's
/// exports, same as `storage.foo` resolves above. Once the type itself
/// resolves, every reference to the variable used as a field access
/// (`s.run()`) chains into the target file via `FieldChain.resolveChain`,
/// same as the same-file case in `SymbolGraph`.
fn buildInstanceTypes(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            if (InstanceType.resolve(semantic, &file.owner_map, sym_id) != null) continue;
            const root = InstanceType.crossFileRoot(semantic, &file.owner_map, sym_id) orelse continue;

            const target = importTargetRoot(project, file.id, root.base) orelse continue;
            const target_file_id = target.file;
            const target_file = project.file(target_file_id);
            const target_semantic = &target_file.semantic;
            const ty = FieldChain.findExport(target_semantic, &target_file.owner_map, target.root, root.field) orelse continue;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = file.owner_map.get(ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };
                try addChain(project, graph, gpa, owner_id, target_file_id, semantic, target_semantic, &target_file.owner_map, ty, ref.node, .possible);
            }
        }
    }
}

/// One of `file_id`'s `@import` edges whose binding symbol is `base`, if
/// any.
fn importEdge(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?ImportGraph.Edge {
    for (project.import_graph.edges.items) |edge| {
        if (edge.from != file_id) continue;
        const binding = project.file(edge.from).owner_map.get(edge.node) orelse continue;
        if (binding == base) return edge;
    }
    return null;
}

/// `importTarget`'s target file plus, if `base` is an alias binding
/// narrowed to one export (see `aliasRoot`), that export — otherwise the
/// target file's own root. The container every `base.field` hop into the
/// target file should resolve against.
fn importTargetRoot(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?struct { file: FileId, root: Semantic.Symbol.Id } {
    const edge = importEdge(project, file_id, base) orelse return null;
    const target_file = project.file(edge.to);
    const from_semantic = &project.file(file_id).semantic;
    const root = aliasRoot(from_semantic, edge.node, &target_file.semantic, &target_file.owner_map) orelse FILE_ROOT_SYMBOL;
    return .{ .file = edge.to, .root = root };
}

/// Phase 17: `var s = Foo.init(...); s.run();`, where `Foo.init` (or its
/// return type) may itself cross one or more `@import` boundaries — a
/// bigger hammer than `buildInstanceTypes`' `InstanceType.crossFileRoot`,
/// which only unwinds one hop, since `Foo.init`'s callee expression and its
/// return-type expression are each resolved independently via
/// `resolveValueChain`.
///
/// For every variable whose initializer is a call expression
/// (`InstanceType.callInit`) and that isn't already resolved by the
/// annotation/struct-literal shapes (`InstanceType.resolve` — same-file —
/// or `InstanceType.crossFileRoot` — one cross-file hop): resolve the
/// callee to a function symbol, read that function's own declared return
/// type (unwrapping one `!error_union` and/or `?optional_type` layer),
/// resolve that expression too, then chain the variable's own references
/// into it the same way `buildInstanceTypes` does once its type is known.
///
/// Phase 19: a generic type-returning function (`fn Walker(comptime V: type)
/// type { return struct { ... }; }`) declares its return type as the bare
/// `type` keyword, not an expression `resolveValueChain` can resolve —
/// there's no name to chase, since the returned type is the anonymous
/// `struct { ... }` literal itself. ZLint's builder attributes that struct's
/// `pub` members as exports of whatever container the *function itself* is
/// declared in (it never pushes the anonymous struct as its own container —
/// see `FieldChain.containerOf`'s doc comment), rather than of the function
/// symbol — so `LintWalker.init` in `const LintWalker = walk.Walker(V); ...
/// LintWalker.init(...)` resolves by treating `LintWalker` as an alias for
/// `Walker`'s own enclosing container (usually `walk.zig`'s file root), the
/// same way `FieldChain.findExport` already resolves a `const Self =
/// @This();` alias to its container.
///
/// Phase 25: `for (seq) |x|` where `seq` is itself one of the above
/// call-init shapes (`const tail = tailOf(...); for (tail) |*e| { ... }`)
/// has no type-position node of its own for `InstanceType.forElementSource`
/// to chain-walk from — `seq`'s element type is only known transitively,
/// from `seq`'s own call-return type. `callInstanceType` falls back to
/// `InstanceType.forElementSequenceSymbol` and recurses into `seq`'s own
/// `callInstanceType` when the direct annotation/struct-literal/call-init
/// shapes all come back empty for the payload symbol itself.
fn buildCallInstanceTypes(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            const ty = callInstanceType(project, file.id, sym_id) orelse continue;
            const ty_file = project.file(ty.file);
            const ty_semantic = &ty_file.semantic;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = file.owner_map.get(ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };
                try addChain(project, graph, gpa, owner_id, ty.file, semantic, ty_semantic, &ty_file.owner_map, ty.local, ref.node, .possible);
            }
        }
    }
}

/// `sym_id`'s type, resolved the way `buildCallInstanceTypes`' doc comment
/// describes, if `sym_id` is declared `var s = Foo.init(...)` (or a
/// generic-type-returning-function equivalent) and isn't already resolved
/// by the cheaper annotation/struct-literal shapes. Exposed for `Roots`'
/// `.test`-root case, which needs the same answer per-symbol rather than
/// graph edges built from it.
pub fn callInstanceType(project: *const Project, file_id: FileId, sym_id: Semantic.Symbol.Id) ?SymbolId {
    const file = project.file(file_id);
    const semantic = &file.semantic;

    if (InstanceType.resolve(semantic, &file.owner_map, sym_id) != null) return null;
    if (InstanceType.crossFileRoot(semantic, &file.owner_map, sym_id) != null) return null;
    const fn_expr = InstanceType.callInit(semantic, sym_id) orelse {
        const seq_sym = InstanceType.forElementSequenceSymbol(semantic, sym_id) orelse return null;
        return callInstanceType(project, file_id, seq_sym);
    };

    const fn_sym = resolveValueChain(project, file_id, fn_expr) orelse return null;
    const fn_semantic = &project.file(fn_sym.file).semantic;
    const fn_symbol = fn_semantic.symbols.get(fn_sym.local);
    if (!fn_symbol.flags.s_fn) return null;

    const fn_ast = &fn_semantic.parse.ast;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = fn_ast.fullFnProto(&proto_buf, fn_symbol.decl) orelse return null;
    var return_node = proto.ast.return_type.unwrap() orelse return null;
    if (fn_ast.nodeTag(return_node) == .error_union) {
        return_node = fn_ast.nodeData(return_node).node_and_node[1];
    }
    if (fn_ast.nodeTag(return_node) == .optional_type) {
        return_node = fn_ast.nodeData(return_node).node;
    }
    if (fn_ast.fullPtrType(return_node)) |ptr| {
        return_node = ptr.ast.child_type;
    }

    if (isTypeKeyword(fn_semantic, return_node)) {
        const fn_owner_map = &project.file(fn_sym.file).owner_map;
        const container = FieldChain.containerOf(fn_semantic, fn_owner_map, fn_sym.local) orelse return null;
        return .{ .file = fn_sym.file, .local = container };
    }
    return resolveValueChain(project, fn_sym.file, return_node);
}

/// Whether `node` is the bare `type` keyword — the return-type spelling of a
/// generic type-returning function (`fn Walker(comptime V: type) type { ...
/// }`), as opposed to a value's own type. ZLint parses it as a plain
/// identifier, so this just checks the token text.
fn isTypeKeyword(semantic: *const Semantic, node: Ast.Node.Index) bool {
    const ast = &semantic.parse.ast;
    return ast.nodeTag(node) == .identifier and std.mem.eql(u8, semantic.tokenSlice(ast.nodeMainToken(node)), "type");
}

/// Resolves a value-position expression node (`node`, in `file_id`'s AST) —
/// a bare identifier, or a chain of `.field` accesses off one — to the
/// symbol it names, crossing as many `@import` boundaries as the chain
/// does (see the module doc comment). `null` if `node` isn't that shape, or
/// any hop doesn't resolve.
fn resolveValueChain(project: *const Project, file_id: FileId, node: Ast.Node.Index) ?SymbolId {
    const semantic = &project.file(file_id).semantic;
    const ast = &semantic.parse.ast;

    return switch (ast.nodeTag(node)) {
        .identifier => blk: {
            const sym = InstanceType.referenceAt(semantic, node) orelse break :blk null;
            break :blk .{ .file = file_id, .local = sym };
        },
        .field_access => blk: {
            const data = ast.nodeData(node).node_and_token;
            const base = resolveValueChain(project, file_id, data[0]) orelse break :blk null;
            break :blk hop(project, base, semantic.tokenSlice(data[1]));
        },
        else => null,
    };
}

/// `base.field`: matched against `base`'s own file's exports first (via
/// `FieldChain.findExport`, which already unwraps a `@This()` alias `base`
/// might be), then — if `base` is itself bound to an `@import` (a
/// re-export) — against the target file's exports instead.
///
/// Issue 10: if neither matches, `base` isn't a container/import binding
/// itself but a field or variable whose own *declared type* is — the
/// `state.channels.get_or_open()` shape, where `channels: table.ChannelTable`
/// is a container field. `declaredType` resolves that type (same-file or
/// across the `@import` boundary it's declared with, same as
/// `FieldChain.resolveChain`'s in-chain redirection does for a stuck hop —
/// see `addChain`), and the hop is retried against it.
fn hop(project: *const Project, base: SymbolId, field: []const u8) ?SymbolId {
    const base_file = project.file(base.file);
    if (FieldChain.findExport(&base_file.semantic, &base_file.owner_map, base.local, field)) |found| {
        return .{ .file = base.file, .local = found };
    }

    if (importTargetRoot(project, base.file, base.local)) |target| {
        const target_file = project.file(target.file);
        if (FieldChain.findExport(&target_file.semantic, &target_file.owner_map, target.root, field)) |found| {
            return .{ .file = target.file, .local = found };
        }
    }

    const ty = declaredType(project, base) orelse return null;
    return hop(project, ty, field);
}

/// `base`'s own declared type, resolved same-file via `InstanceType.resolve`
/// or, if the type expression itself crosses an `@import` boundary
/// (`InstanceType.crossFileRoot`), by resolving that boundary the same way
/// `importTargetRoot` + `FieldChain.findExport` already do for a binding's
/// own field hops above. `null` if `base` has no syntactically-resolvable
/// declared type.
fn declaredType(project: *const Project, base: SymbolId) ?SymbolId {
    const base_file = project.file(base.file);
    const semantic = &base_file.semantic;
    const owner_map = &base_file.owner_map;

    if (InstanceType.resolve(semantic, owner_map, base.local)) |ty| {
        return .{ .file = base.file, .local = ty };
    }

    const root = InstanceType.crossFileRoot(semantic, owner_map, base.local) orelse return null;
    const target = importTargetRoot(project, base.file, root.base) orelse return null;
    const target_file = project.file(target.file);
    const ty = FieldChain.findExport(&target_file.semantic, &target_file.owner_map, target.root, root.field) orelse return null;
    return .{ .file = target.file, .local = ty };
}

/// Continues resolving `start` (declared in `symbols`, first referenced at
/// `start_node` in `ast`) via `FieldChain.resolveChain` at `start_kind`
/// confidence, adding an edge to wherever the chain ends up, plus `.unknown`
/// edges to every export if it stopped at a runtime-named `@field(...)` hop.
///
/// Phase 22: if the walk gets stuck on a field/variable whose own declared
/// type crosses another `@import` boundary (`h.foo.bar()`, where `foo`'s
/// type is `mod.Foo`) — the same shape `buildInstanceTypes` resolves for a
/// chain's *starting* symbol, just reached mid-chain instead — resolves that
/// hop the same way (`InstanceType.crossFileRoot` + `importTargetRoot` +
/// `FieldChain.findExport`) and resumes the walk in the target file. Loops
/// since the newly-resolved type can itself have a field with yet another
/// cross-file type.
fn addChain(
    project: *const Project,
    graph: *SymbolGraph,
    gpa: Allocator,
    owner_id: SymbolId,
    target_file: FileId,
    ast: *const Semantic,
    symbols: *const Semantic,
    owner_map: *const OwnerMap,
    start: Semantic.Symbol.Id,
    start_node: Semantic.Ast.Node.Index,
    start_kind: FieldChain.Kind,
) !void {
    var cur_file = target_file;
    var cur_symbols = symbols;
    var cur_owner_map = owner_map;
    var chain = FieldChain.resolveChain(ast, cur_symbols, cur_owner_map, start, start_node, start_kind);

    while (chain.stuck) |stuck| {
        const root = InstanceType.crossFileRoot(cur_symbols, cur_owner_map, stuck.symbol) orelse break;
        const target = importTargetRoot(project, cur_file, root.base) orelse break;
        const next_file = project.file(target.file);
        const next_semantic = &next_file.semantic;
        const ty = FieldChain.findExport(next_semantic, &next_file.owner_map, target.root, root.field) orelse break;

        cur_file = target.file;
        cur_symbols = next_semantic;
        cur_owner_map = &next_file.owner_map;
        chain = FieldChain.resolveChain(ast, cur_symbols, cur_owner_map, ty, stuck.node, stuck.kind);
    }

    const kind: SymbolGraph.EdgeKind = switch (chain.result.kind) {
        .definite => .definite,
        .possible => .possible,
    };
    try graph.addEdge(gpa, owner_id, .{ .file = cur_file, .local = chain.result.symbol }, chain.result.node, kind);
    if (chain.unknown) |unknown| for (unknown.exports) |target| {
        try graph.addEdge(gpa, owner_id, .{ .file = cur_file, .local = target }, unknown.node, .unknown);
    };
}
