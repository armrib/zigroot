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
//! Only resolves that one shape. `Foo.bar()` static-member access and
//! instance-method calls are Phase 7+; anything else is silently left
//! unresolved rather than guessed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;

const Project = @import("../Project.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;
const SymbolGraph = @import("SymbolGraph.zig");

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
            const field_name = fieldAccessName(&from_file.semantic, ref.node) orelse continue;
            const target_local = findExport(target_semantic, field_name) orelse continue;
            const owner = from_file.owner_map.get(ref.node) orelse continue;

            try graph.addEdge(
                gpa,
                .{ .file = import_edge.from, .local = owner },
                .{ .file = import_edge.to, .local = target_local },
                ref.node,
            );
        }
    }

    return graph;
}

/// If `node` is used as the base of a field access (`node.field`), that
/// field's name. `null` if `node` isn't a field-access base.
fn fieldAccessName(semantic: *const Semantic, node: Semantic.Ast.Node.Index) ?[]const u8 {
    const parent = semantic.node_links.getParent(node) orelse return null;
    if (semantic.parse.ast.nodeTag(parent) != .field_access) return null;
    const data = semantic.parse.ast.nodeData(parent).node_and_token;
    if (data[0] != node) return null;
    return semantic.tokenSlice(data[1]);
}

fn findExport(semantic: *const Semantic, name: []const u8) ?Semantic.Symbol.Id {
    for (semantic.symbols.getExports(FILE_ROOT_SYMBOL).items) |id| {
        if (std.mem.eql(u8, semantic.symbols.get(id).name, name)) return id;
    }
    return null;
}
