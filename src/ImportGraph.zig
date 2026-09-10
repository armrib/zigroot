//! File-level `@import` edges across a `Project`.
//!
//! This only tracks *file* imports (`@import("foo.zig")`) that resolve to
//! another file on disk. Named-module imports (`@import("std")`,
//! `@import("some_dep")`) and file imports that don't resolve are recorded
//! as `unresolved` instead of an edge, since resolving them needs build.zig
//! module information we don't have yet (see the architecture notes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");

const FileId = @import("FileId.zig").FileId;
const ImportKind = zlint.Semantic.ModuleRecord.ImportEntry.Kind;

const ImportGraph = @This();

pub const Edge = struct {
    from: FileId,
    to: FileId,
    node: zlint.Semantic.Ast.Node.Index,
};

pub const UnresolvedImport = struct {
    from: FileId,
    /// The raw `@import(...)` argument. Owned.
    specifier: []const u8,
    kind: ImportKind,
    node: zlint.Semantic.Ast.Node.Index,
};

edges: std.ArrayListUnmanaged(Edge) = .empty,
unresolved: std.ArrayListUnmanaged(UnresolvedImport) = .empty,
/// from -> [to, to, ...]
adjacency: std.AutoHashMapUnmanaged(FileId, std.ArrayListUnmanaged(FileId)) = .empty,

pub const empty: ImportGraph = .{};

pub fn deinit(self: *ImportGraph, gpa: Allocator) void {
    self.edges.deinit(gpa);
    for (self.unresolved.items) |u| gpa.free(u.specifier);
    self.unresolved.deinit(gpa);
    var it = self.adjacency.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    self.adjacency.deinit(gpa);
    self.* = undefined;
}

pub fn addEdge(self: *ImportGraph, gpa: Allocator, from: FileId, to: FileId, node: zlint.Semantic.Ast.Node.Index) !void {
    try self.edges.append(gpa, .{ .from = from, .to = to, .node = node });
    const gop = try self.adjacency.getOrPut(gpa, from);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(gpa, to);
}

pub fn addUnresolved(
    self: *ImportGraph,
    gpa: Allocator,
    from: FileId,
    specifier: []const u8,
    kind: ImportKind,
    node: zlint.Semantic.Ast.Node.Index,
) !void {
    try self.unresolved.append(gpa, .{
        .from = from,
        .specifier = try gpa.dupe(u8, specifier),
        .kind = kind,
        .node = node,
    });
}

/// Files directly imported by `file`. Empty slice if `file` imports nothing
/// resolvable.
pub fn outgoing(self: *const ImportGraph, file: FileId) []const FileId {
    if (self.adjacency.get(file)) |list| return list.items;
    return &.{};
}
