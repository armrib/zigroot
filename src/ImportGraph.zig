//! File-level `@import` edges across a `Project`.
//!
//! This only tracks *file* imports (`@import("foo.zig")`) that resolve to
//! another file on disk. Named-module imports (`@import("std")`,
//! `@import("some_dep")`) and file imports that don't resolve are recorded
//! as `unresolved` instead of an edge, since resolving them needs build.zig
//! module information we don't have yet (see the architecture notes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");

const FileId = @import("FileId.zig").FileId;
const ImportKind = Semantic.ModuleRecord.ImportEntry.Kind;

const ImportGraph = @This();

pub const Edge = struct {
    from: FileId,
    to: FileId,
    node: Semantic.Ast.Node.Index,
};

pub const UnresolvedImport = struct {
    from: FileId,
    /// The raw `@import(...)` argument. Owned.
    specifier: []const u8,
    kind: ImportKind,
    node: Semantic.Ast.Node.Index,
    reason: Reason,

    pub const Reason = enum {
        /// A module the project doesn't own: `std`, `builtin`, `root`, a
        /// `build.zig.zon` dependency, or a name `build.zig` wires in via
        /// `addImport` from a `b.dependency(...)`. Never a configuration
        /// gap, and never a source of roots — a reachability sink.
        external,
        /// A named module nothing in `build.zig`/`build.zig.zon` accounts
        /// for. A real configuration gap worth reporting.
        unknown_module,
        /// `@import("foo.c")`, `@import("build.zig.zon")`: not a `.zig`
        /// file, so there's nothing to analyze.
        not_a_zig_file,
        /// A `.zig` file that couldn't be read or parsed at the resolved
        /// path.
        load_failed,
    };
};

edges: std.ArrayListUnmanaged(Edge) = .empty,
unresolved: std.ArrayListUnmanaged(UnresolvedImport) = .empty,
/// from -> [edge, edge, ...], the same edges as `edges` grouped by source
/// file so a lookup for one file's imports doesn't scan the whole project.
edges_by_from: std.AutoHashMapUnmanaged(FileId, std.ArrayListUnmanaged(Edge)) = .empty,

pub const empty: ImportGraph = .{};

pub fn deinit(self: *ImportGraph, gpa: Allocator) void {
    self.edges.deinit(gpa);
    for (self.unresolved.items) |u| gpa.free(u.specifier);
    self.unresolved.deinit(gpa);
    var by_from_it = self.edges_by_from.valueIterator();
    while (by_from_it.next()) |list| list.deinit(gpa);
    self.edges_by_from.deinit(gpa);
    self.* = undefined;
}

pub fn addEdge(self: *ImportGraph, gpa: Allocator, from: FileId, to: FileId, node: Semantic.Ast.Node.Index) !void {
    const edge: Edge = .{ .from = from, .to = to, .node = node };
    try self.edges.append(gpa, edge);
    const by_from_gop = try self.edges_by_from.getOrPut(gpa, from);
    if (!by_from_gop.found_existing) by_from_gop.value_ptr.* = .empty;
    try by_from_gop.value_ptr.append(gpa, edge);
}

/// `from`'s own `@import` edges. Empty slice if `from` imports nothing
/// resolvable.
pub fn edgesFrom(self: *const ImportGraph, from: FileId) []const Edge {
    if (self.edges_by_from.get(from)) |list| return list.items;
    return &.{};
}

pub fn addUnresolved(
    self: *ImportGraph,
    gpa: Allocator,
    from: FileId,
    specifier: []const u8,
    kind: ImportKind,
    node: Semantic.Ast.Node.Index,
    reason: UnresolvedImport.Reason,
) !void {
    try self.unresolved.append(gpa, .{
        .from = from,
        .specifier = try gpa.dupe(u8, specifier),
        .kind = kind,
        .node = node,
        .reason = reason,
    });
}
