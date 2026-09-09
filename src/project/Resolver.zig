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

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;

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
