//! Phase 10: Tarjan's algorithm for strongly connected components over the
//! project's declaration graph (`SymbolGraph` per file, plus `Resolver`'s
//! cross-file edges), so a cycle of mutually-referencing-but-globally-dead
//! declarations (`fn a() { b(); } fn b() { a(); }`, neither reachable from
//! any root) is reported as one finding instead of N.
//!
//! Only `.definite`/`.possible` edges are followed — the same edge set
//! `Reachability`'s BFS trusts. `.unknown` edges are a guess, not a fact;
//! folding them into a component would risk lumping a live symbol in with
//! genuinely dead ones.
//!
//! A component of size 1 is only "cyclic" if its one member has an edge to
//! itself (direct recursion); that's detected in a second pass over every
//! edge, since Tarjan's core algorithm alone doesn't distinguish a lone
//! self-recursive node from a lone node with no self-edge.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Project = @import("../Project.zig");
const SymbolGraph = @import("SymbolGraph.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

const Scc = @This();

pub const ComponentId = enum(u32) { _ };

/// components.items[@intFromEnum(id)] = every symbol in component `id`.
components: std.ArrayListUnmanaged(std.ArrayListUnmanaged(SymbolId)) = .empty,
/// components.items[@intFromEnum(id)] has an edge from some member to some
/// member (a self-loop counts): a genuine cycle, not just an SCC of
/// convenience around an isolated node.
cyclic: std.ArrayListUnmanaged(bool) = .empty,
component_of: std.AutoHashMapUnmanaged(SymbolId, ComponentId) = .empty,

pub const empty: Scc = .{};

pub fn deinit(self: *Scc, gpa: Allocator) void {
    for (self.components.items) |*c| c.deinit(gpa);
    self.components.deinit(gpa);
    self.cyclic.deinit(gpa);
    self.component_of.deinit(gpa);
    self.* = undefined;
}

pub fn componentOf(self: *const Scc, id: SymbolId) ?ComponentId {
    return self.component_of.get(id);
}

pub fn members(self: *const Scc, component: ComponentId) []const SymbolId {
    return self.components.items[@intFromEnum(component)].items;
}

pub fn isCyclic(self: *const Scc, component: ComponentId) bool {
    return self.cyclic.items[@intFromEnum(component)];
}

fn outgoing(project: *const Project, cross_file: *const SymbolGraph, from: SymbolId, buf: *std.ArrayListUnmanaged(SymbolId), gpa: Allocator) Allocator.Error!void {
    buf.clearRetainingCapacity();
    for (project.file(from.file).symbol_graph.outgoing(from)) |target| {
        if (target.kind == .unknown) continue;
        try buf.append(gpa, target.to);
    }
    for (cross_file.outgoing(from)) |target| {
        if (target.kind == .unknown) continue;
        try buf.append(gpa, target.to);
    }
}

const Tarjan = struct {
    gpa: Allocator,
    project: *const Project,
    cross_file: *const SymbolGraph,
    next_index: u32 = 0,
    index_of: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    lowlink: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    on_stack: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    stack: std.ArrayListUnmanaged(SymbolId) = .empty,
    scratch: std.ArrayListUnmanaged(SymbolId) = .empty,
    scc: Scc = .empty,

    fn deinitScratch(self: *Tarjan) void {
        self.index_of.deinit(self.gpa);
        self.lowlink.deinit(self.gpa);
        self.on_stack.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
    }

    fn strongConnect(self: *Tarjan, v: SymbolId) Allocator.Error!void {
        try self.index_of.put(self.gpa, v, self.next_index);
        try self.lowlink.put(self.gpa, v, self.next_index);
        self.next_index += 1;
        try self.stack.append(self.gpa, v);
        try self.on_stack.put(self.gpa, v, {});

        var succ: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer succ.deinit(self.gpa);
        try outgoing(self.project, self.cross_file, v, &succ, self.gpa);

        for (succ.items) |w| {
            if (!self.index_of.contains(w)) {
                try self.strongConnect(w);
                self.lowlink.getPtr(v).?.* = @min(self.lowlink.get(v).?, self.lowlink.get(w).?);
            } else if (self.on_stack.contains(w)) {
                self.lowlink.getPtr(v).?.* = @min(self.lowlink.get(v).?, self.index_of.get(w).?);
            }
        }

        if (self.lowlink.get(v).? != self.index_of.get(v).?) return;

        const id: ComponentId = @enumFromInt(@as(u32, @intCast(self.scc.components.items.len)));
        var component: std.ArrayListUnmanaged(SymbolId) = .empty;
        while (true) {
            const w = self.stack.pop().?;
            _ = self.on_stack.remove(w);
            try component.append(self.gpa, w);
            try self.scc.component_of.put(self.gpa, w, id);
            if (w.eql(v)) break;
        }
        try self.scc.components.append(self.gpa, component);
        try self.scc.cyclic.append(self.gpa, false);
    }
};

/// Builds SCCs over every declared symbol in `project`, following
/// `.definite`/`.possible` edges from each file's `SymbolGraph` and from
/// `cross_file` (`Resolver`'s `@import`-resolved edges).
pub fn build(gpa: Allocator, project: *const Project, cross_file: *const SymbolGraph) Allocator.Error!Scc {
    var tarjan: Tarjan = .{ .gpa = gpa, .project = project, .cross_file = cross_file };
    errdefer tarjan.scc.deinit(gpa);
    defer tarjan.deinitScratch();

    for (project.files.items) |f| {
        var it = f.semantic.symbols.iter();
        while (it.next()) |local| {
            const id: SymbolId = .{ .file = f.id, .local = local };
            if (tarjan.index_of.contains(id)) continue;
            try tarjan.strongConnect(id);
        }
    }

    var scc = tarjan.scc;
    errdefer scc.deinit(gpa);

    var succ: std.ArrayListUnmanaged(SymbolId) = .empty;
    defer succ.deinit(gpa);
    for (project.files.items) |f| {
        var it = f.semantic.symbols.iter();
        while (it.next()) |local| {
            const from: SymbolId = .{ .file = f.id, .local = local };
            const from_component = scc.component_of.get(from) orelse continue;
            try outgoing(project, cross_file, from, &succ, gpa);
            for (succ.items) |to| {
                const to_component = scc.component_of.get(to) orelse continue;
                if (to_component == from_component) {
                    scc.cyclic.items[@intFromEnum(from_component)] = true;
                }
            }
        }
    }

    return scc;
}
