//! Phase 5: BFS reachability over `SymbolGraph` starting from `Roots`,
//! `O(V+E)` in the number of symbols and edges visited.
//!
//! Also follows Phase 6's cross-file `Resolver` edges, so a symbol only
//! referenced through `@import` (`storage.start()`) counts as reached.
//!
//! Phase 9: `SymbolGraph.EdgeKind.unknown` edges (e.g. `@field(Foo, name)`
//! with a runtime name) are *not* followed by this BFS — their fan-out is a
//! guess, not a fact, so treating every plausible target as definitely
//! reached would hide real dead code. Instead, once the BFS settles, every
//! `unknown` edge whose source *is* reached marks its target
//! `possiblyReachable` — not dead-for-certain, but not silently dropped
//! either. `deadSymbols` reports these separately so callers can choose
//! whether to trust them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Project = @import("../Project.zig");
const Roots = @import("Roots.zig");
const SymbolGraph = @import("SymbolGraph.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

const Reachability = @This();

reached: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
/// Targets of an `.unknown` edge whose source is reached, but that aren't
/// themselves reached by any `.definite`/`.possible` path.
possibly_reached: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,

pub const empty: Reachability = .{};

pub fn deinit(self: *Reachability, gpa: Allocator) void {
    self.reached.deinit(gpa);
    self.possibly_reached.deinit(gpa);
    self.* = undefined;
}

pub fn isReachable(self: *const Reachability, id: SymbolId) bool {
    return self.reached.contains(id);
}

pub fn isPossiblyReachable(self: *const Reachability, id: SymbolId) bool {
    return self.possibly_reached.contains(id);
}

/// BFS from every root in `roots`, following `project`'s per-file
/// `SymbolGraph.outgoing` edges plus `cross_file`'s (Phase 6's `Resolver`
/// output) `@import`-resolved edges. Only `.definite`/`.possible` edges are
/// followed; `.unknown` edges are resolved into `possibly_reached` in a
/// second pass, once `reached` is final.
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
        for (graph.outgoing(current)) |target| {
            if (target.kind == .unknown) continue;
            if (reachability.reached.contains(target.to)) continue;
            try reachability.reached.put(gpa, target.to, {});
            try queue.append(gpa, target.to);
        }
        for (cross_file.outgoing(current)) |target| {
            if (target.kind == .unknown) continue;
            if (reachability.reached.contains(target.to)) continue;
            try reachability.reached.put(gpa, target.to, {});
            try queue.append(gpa, target.to);
        }
    }

    for (project.files.items) |f| {
        try reachability.collectUnknown(gpa, &f.symbol_graph);
    }
    try reachability.collectUnknown(gpa, cross_file);

    return reachability;
}

fn collectUnknown(self: *Reachability, gpa: Allocator, graph: *const SymbolGraph) Allocator.Error!void {
    for (graph.edges.items) |edge| {
        if (edge.kind != .unknown) continue;
        if (!self.reached.contains(edge.from)) continue;
        if (self.reached.contains(edge.to)) continue;
        try self.possibly_reached.put(gpa, edge.to, {});
    }
}

/// Every symbol declared in `project` that `build` did not mark reachable,
/// tagged with whether it's only "possibly" dead (Phase 9: reached by an
/// `.unknown` edge from a live call site — e.g. a plausible
/// `@field(Foo, name)` target).
/// Skips `extern` declarations (Phase 8): their implementation lives
/// outside the project, so local reachability alone can never justify
/// calling them dead.
/// Caller owns the returned list.
pub fn deadSymbols(self: *const Reachability, gpa: Allocator, project: *const Project) Allocator.Error!std.ArrayListUnmanaged(Dead) {
    var dead: std.ArrayListUnmanaged(Dead) = .empty;
    errdefer dead.deinit(gpa);

    for (project.files.items) |f| {
        var it = f.semantic.symbols.iter();
        while (it.next()) |local| {
            if (f.semantic.symbols.get(local).flags.s_extern) continue;
            const id: SymbolId = .{ .file = f.id, .local = local };
            if (self.isReachable(id)) continue;
            try dead.append(gpa, .{ .id = id, .possible = self.isPossiblyReachable(id) });
        }
    }

    return dead;
}

pub const Dead = struct {
    id: SymbolId,
    possible: bool,
};
