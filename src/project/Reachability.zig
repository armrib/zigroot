//! Phase 5: BFS reachability over `SymbolGraph` starting from `Roots`,
//! `O(V+E)` in the number of symbols and edges visited.
//!
//! Also follows Phase 6's cross-file `Resolver` edges, so a symbol only
//! referenced through `@import` (`storage.start()`) counts as reached.
//! Anything `Resolver` couldn't statically resolve is still invisible here —
//! that's Phase 9's confidence levels.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Project = @import("../Project.zig");
const Roots = @import("Roots.zig");
const SymbolGraph = @import("SymbolGraph.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

const Reachability = @This();

reached: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,

pub const empty: Reachability = .{};

pub fn deinit(self: *Reachability, gpa: Allocator) void {
    self.reached.deinit(gpa);
    self.* = undefined;
}

pub fn isReachable(self: *const Reachability, id: SymbolId) bool {
    return self.reached.contains(id);
}

/// BFS from every root in `roots`, following `project`'s per-file
/// `SymbolGraph.outgoing` edges plus `cross_file`'s (Phase 6's `Resolver`
/// output) `@import`-resolved edges.
pub fn build(gpa: Allocator, project: *const Project, roots: *const Roots, cross_file: *const SymbolGraph) Allocator.Error!Reachability {
    var reachability: Reachability = .empty;
    errdefer reachability.deinit(gpa);

    var queue: std.ArrayListUnmanaged(SymbolId) = .empty;
    defer queue.deinit(gpa);

    for (roots.roots.items) |root| {
        if (reachability.reached.contains(root.symbol)) continue;
        try reachability.reached.put(gpa, root.symbol, {});
        try queue.append(gpa, root.symbol);
    }

    while (queue.pop()) |current| {
        const graph = &project.file(current.file).symbol_graph;
        for (graph.outgoing(current)) |next| {
            if (reachability.reached.contains(next)) continue;
            try reachability.reached.put(gpa, next, {});
            try queue.append(gpa, next);
        }
        for (cross_file.outgoing(current)) |next| {
            if (reachability.reached.contains(next)) continue;
            try reachability.reached.put(gpa, next, {});
            try queue.append(gpa, next);
        }
    }

    return reachability;
}

/// Every symbol declared in `project` that `build` did not mark reachable.
/// Caller owns the returned list.
pub fn deadSymbols(self: *const Reachability, gpa: Allocator, project: *const Project) Allocator.Error!std.ArrayListUnmanaged(SymbolId) {
    var dead: std.ArrayListUnmanaged(SymbolId) = .empty;
    errdefer dead.deinit(gpa);

    for (project.files.items) |f| {
        var it = f.semantic.symbols.iter();
        while (it.next()) |local| {
            const id: SymbolId = .{ .file = f.id, .local = local };
            if (!self.isReachable(id)) try dead.append(gpa, id);
        }
    }

    return dead;
}
