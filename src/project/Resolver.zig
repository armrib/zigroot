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

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;

const Project = @import("../Project.zig");
const FileId = @import("FileId.zig").FileId;
const SymbolId = @import("SymbolId.zig").SymbolId;
const SymbolGraph = @import("SymbolGraph.zig");
const FieldChain = @import("FieldChain.zig");
const DynamicField = @import("DynamicField.zig");
const InstanceType = @import("InstanceType.zig");

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
        const target_semantic = &project.file(import_edge.to).semantic;

        var ref_it = from_file.semantic.symbols.iterReferences(binding);
        while (ref_it.next()) |ref| {
            const owner = from_file.owner_map.get(ref.node) orelse continue;
            const owner_id: SymbolId = .{ .file = import_edge.from, .local = owner };

            if (FieldChain.fieldAccessName(&from_file.semantic, ref.node)) |field_name| {
                const target_local = FieldChain.findExport(target_semantic, FILE_ROOT_SYMBOL, field_name) orelse continue;
                const field_node = from_file.semantic.node_links.getParent(ref.node).?;
                try addChain(&graph, gpa, owner_id, import_edge.to, &from_file.semantic, target_semantic, target_local, field_node, .definite);
                continue;
            }

            if (DynamicField.resolve(&from_file.semantic, target_semantic, FILE_ROOT_SYMBOL, ref.node)) |resolution| switch (resolution) {
                .possible => |target| {
                    const field_node = from_file.semantic.node_links.getParent(ref.node).?;
                    try addChain(&graph, gpa, owner_id, import_edge.to, &from_file.semantic, target_semantic, target, field_node, .possible);
                },
                .unknown => |exports| for (exports) |target| {
                    try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = target }, ref.node, .unknown);
                },
            };
        }
    }

    try buildInstanceTypes(gpa, &graph, project);
    try buildCallInstanceTypes(gpa, &graph, project);

    return graph;
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
            if (InstanceType.resolve(semantic, sym_id) != null) continue;
            const root = InstanceType.crossFileRoot(semantic, sym_id) orelse continue;

            const target_file = importTarget(project, file.id, root.base) orelse continue;
            const target_semantic = &project.file(target_file).semantic;
            const ty = FieldChain.findExport(target_semantic, FILE_ROOT_SYMBOL, root.field) orelse continue;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = file.owner_map.get(ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };
                try addChain(graph, gpa, owner_id, target_file, semantic, target_semantic, ty, ref.node, .possible);
            }
        }
    }
}

/// The target file of one of `file_id`'s `@import` edges whose binding
/// symbol is `base`, if any.
fn importTarget(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?FileId {
    for (project.import_graph.edges.items) |edge| {
        if (edge.from != file_id) continue;
        const binding = project.file(edge.from).owner_map.get(edge.node) orelse continue;
        if (binding == base) return edge.to;
    }
    return null;
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
/// type (unwrapping one `!error_union` payload), resolve that expression
/// too, then chain the variable's own references into it the same way
/// `buildInstanceTypes` does once its type is known.
fn buildCallInstanceTypes(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            if (InstanceType.resolve(semantic, sym_id) != null) continue;
            if (InstanceType.crossFileRoot(semantic, sym_id) != null) continue;
            const fn_expr = InstanceType.callInit(semantic, sym_id) orelse continue;

            const fn_sym = resolveValueChain(project, file.id, fn_expr) orelse continue;
            const fn_semantic = &project.file(fn_sym.file).semantic;
            const fn_symbol = fn_semantic.symbols.get(fn_sym.local);
            if (!fn_symbol.flags.s_fn) continue;

            const fn_ast = &fn_semantic.parse.ast;
            var proto_buf: [1]Ast.Node.Index = undefined;
            const proto = fn_ast.fullFnProto(&proto_buf, fn_symbol.decl) orelse continue;
            var return_node = proto.ast.return_type.unwrap() orelse continue;
            if (fn_ast.nodeTag(return_node) == .error_union) {
                return_node = fn_ast.nodeData(return_node).node_and_node[1];
            }

            const ty = resolveValueChain(project, fn_sym.file, return_node) orelse continue;
            const ty_semantic = &project.file(ty.file).semantic;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = file.owner_map.get(ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };
                try addChain(graph, gpa, owner_id, ty.file, semantic, ty_semantic, ty.local, ref.node, .possible);
            }
        }
    }
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
fn hop(project: *const Project, base: SymbolId, field: []const u8) ?SymbolId {
    const base_semantic = &project.file(base.file).semantic;
    if (FieldChain.findExport(base_semantic, base.local, field)) |found| {
        return .{ .file = base.file, .local = found };
    }

    const target_file = importTarget(project, base.file, base.local) orelse return null;
    const target_semantic = &project.file(target_file).semantic;
    const found = FieldChain.findExport(target_semantic, FILE_ROOT_SYMBOL, field) orelse return null;
    return .{ .file = target_file, .local = found };
}

/// Continues resolving `start` (declared in `symbols`, first referenced at
/// `start_node` in `ast`) via `FieldChain.resolveChain` at `start_kind`
/// confidence, adding an edge to wherever the chain ends up in
/// `target_file`, plus `.unknown` edges to every export if it stopped at a
/// runtime-named `@field(...)` hop.
fn addChain(
    graph: *SymbolGraph,
    gpa: Allocator,
    owner_id: SymbolId,
    target_file: FileId,
    ast: *const Semantic,
    symbols: *const Semantic,
    start: Semantic.Symbol.Id,
    start_node: Semantic.Ast.Node.Index,
    start_kind: FieldChain.Kind,
) !void {
    const chain = FieldChain.resolveChain(ast, symbols, start, start_node, start_kind);
    const kind: SymbolGraph.EdgeKind = switch (chain.result.kind) {
        .definite => .definite,
        .possible => .possible,
    };
    try graph.addEdge(gpa, owner_id, .{ .file = target_file, .local = chain.result.symbol }, chain.result.node, kind);
    if (chain.unknown) |unknown| for (unknown.exports) |target| {
        try graph.addEdge(gpa, owner_id, .{ .file = target_file, .local = target }, unknown.node, .unknown);
    };
}
