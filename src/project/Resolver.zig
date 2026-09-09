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
//! `@import` boundary too. Instance-method calls still aren't attempted —
//! that needs real type inference.
//!
//! Phase 12: a reference to the binding used as the container argument of
//! `@field(storage, name)` is resolved the same way, via `DynamicField`
//! against the target file's exports — a comptime-known name at `.possible`
//! confidence, a runtime name as `.unknown` edges to every export.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;

const Project = @import("../Project.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;
const SymbolGraph = @import("SymbolGraph.zig");
const FieldChain = @import("FieldChain.zig");
const DynamicField = @import("DynamicField.zig");

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
                const chained = FieldChain.resolve(&from_file.semantic, target_semantic, target_local, field_node);

                try graph.addEdge(
                    gpa,
                    owner_id,
                    .{ .file = import_edge.to, .local = chained.symbol },
                    chained.node,
                    .definite,
                );
                continue;
            }

            if (DynamicField.resolve(&from_file.semantic, target_semantic, FILE_ROOT_SYMBOL, ref.node)) |resolution| switch (resolution) {
                .possible => |target| try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = target }, ref.node, .possible),
                .unknown => |exports| for (exports) |target| {
                    try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = target }, ref.node, .unknown);
                },
            };
        }
    }

    return graph;
}
