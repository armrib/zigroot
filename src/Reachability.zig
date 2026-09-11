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
const Semantic = @import("semantic/Semantic.zig");

const File = @import("File.zig");
const Project = @import("Project.zig");
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

    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const current = queue.items[cursor];
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
/// calling them dead. Also skips any symbol named `_` (e.g. a `catch |_|`
/// or `else |_|` error capture): it's Zig's discard binding, structurally
/// unreferenceable, so it's always "dead" and flagging it is pure noise.
///
/// A dead declaration whose owner (per `OwnerMap`) is itself dead is
/// suppressed here: everything nested inside a dead parent (locals,
/// parameters, enum members, a self-referencing closure) is dead for the
/// same reason its parent is, and reporting each separately turns one
/// actionable finding into a dozen. Only the outermost dead declaration in
/// such a chain is returned, with `nested` counting how many descendants
/// were folded into it.
///
/// Only *declarations* are reported (`isReportable`): a `fn`/`const`/`var`
/// declared directly in a container, i.e. something a user deletes as a
/// unit. Parameters, locals, loop/catch captures and container fields are
/// never findings of their own — an unused parameter of a live function
/// is the compiler's business (`unused function parameter`), and deleting
/// a field changes a type's layout for every user. They still count as
/// `nested` descendants of a dead declaration, and `build` still walks
/// them: a local that references a function creates the edge
/// `enclosing_fn -> function` through `OwnerMap`, so the filter only
/// affects reporting, never reachability.
///
/// Caller owns the returned list.
pub fn deadSymbols(self: *const Reachability, gpa: Allocator, project: *const Project) Allocator.Error!std.ArrayListUnmanaged(Dead) {
    var all: std.ArrayListUnmanaged(SymbolId) = .empty;
    defer all.deinit(gpa);

    var dead_ids: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer dead_ids.deinit(gpa);

    for (project.files.items) |f| {
        var it = f.semantic.symbols.iter();
        while (it.next()) |local| {
            const sym = f.semantic.symbols.get(local);
            if (sym.flags.s_extern) continue;
            if (std.mem.eql(u8, sym.name, "_")) continue;
            if (sym.flags.s_fn_param and isBareFnTypeParam(&f, sym.decl)) continue;
            const id: SymbolId = .{ .file = f.id, .local = local };
            if (self.isReachable(id)) continue;
            try dead_ids.put(gpa, id, {});
            try all.append(gpa, id);
        }
    }

    var nested_count: std.AutoHashMapUnmanaged(SymbolId, usize) = .empty;
    defer nested_count.deinit(gpa);

    for (all.items) |id| {
        const outermost = outermostDead(project, &dead_ids, id);
        if (outermost.eql(id)) continue;
        const gop = try nested_count.getOrPut(gpa, outermost);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var dead: std.ArrayListUnmanaged(Dead) = .empty;
    errdefer dead.deinit(gpa);

    for (all.items) |id| {
        if (!outermostDead(project, &dead_ids, id).eql(id)) continue;
        if (!isReportable(project, id)) continue;
        try dead.append(gpa, .{
            .id = id,
            .possible = self.isPossiblyReachable(id),
            .nested = nested_count.get(id) orelse 0,
        });
    }

    return dead;
}

/// Whether `id` is a declaration a user would delete as a unit — see
/// `deadSymbols`. True for a named `fn`, `const` or `var` whose declaring
/// scope is a container (the file's top level, or a `struct`/`enum`/
/// `union` body) rather than a function body or block; false for
/// parameters, control-flow payloads, `catch` captures, container fields
/// and enum tags, and the `_` discard.
pub fn isReportable(project: *const Project, id: SymbolId) bool {
    const f = project.file(id.file);
    const sym = f.semantic.symbols.get(id.local);
    if (sym.name.len == 0 or std.mem.eql(u8, sym.name, "_")) return false;
    if (sym.flags.s_fn_param or sym.flags.s_payload or sym.flags.s_catch_param or sym.flags.s_member) return false;
    if (!(sym.flags.s_fn or sym.flags.s_const or sym.flags.s_variable)) return false;
    // A container body's scope carries `s_block` alongside `s_struct`/...,
    // so only `s_function` (the body of a fn) rules a scope out directly;
    // a plain block inside a function has none of the container flags.
    const scope = f.semantic.scopes.getScope(sym.scope).flags;
    if (scope.s_function or scope.s_test) return false;
    return scope.s_top or scope.s_struct or scope.s_enum or scope.s_union;
}

/// Whether `decl` (a `s_fn_param` symbol's declaration node — its type
/// expression, or, for an `anytype` param, its enclosing function's own
/// node) belongs to a bare function-*type* expression (`*const fn (ctx:
/// *anyopaque) void` used as a value/field type) rather than a real function
/// declaration. Named parameters in the former are pure documentation —
/// there's no scope in which referencing them would even be syntactically
/// valid, so flagging them dead conveys nothing actionable.
///
/// Climbs `decl`'s parent chain looking for the nearest `fn_proto*` node;
/// that node's own parent is `.fn_decl` for a real function declaration
/// (which wraps a `fn_proto*` node together with a body) and anything else
/// for a bare function-type expression (which stands alone, e.g. as a
/// `container_field`'s type or wrapped in pointer/optional syntax).
fn isBareFnTypeParam(f: *const File, decl: Semantic.Ast.Node.Index) bool {
    const ast = &f.semantic.parse.ast;
    if (ast.nodeTag(decl) == .fn_decl) return false;
    var cur: ?Semantic.Ast.Node.Index = decl;
    while (cur) |c| : (cur = f.semantic.node_links.getParent(c)) {
        switch (ast.nodeTag(c)) {
            .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                const parent = f.semantic.node_links.getParent(c) orelse return true;
                return ast.nodeTag(parent) != .fn_decl;
            },
            else => {},
        }
    }
    return false;
}

/// The declaration `id`'s owner (per `OwnerMap`), or `null` if `id` isn't
/// nested inside another declaration.
fn ownerOf(project: *const Project, id: SymbolId) ?SymbolId {
    const f = project.file(id.file);
    const sym = f.semantic.symbols.get(id.local);
    // An `anytype` parameter has no type-expression node of its own, so
    // ZLint declares it at the same node as its enclosing function — the
    // function claims that node in `OwnerMap`'s `self_decl`, so the
    // parameter's owner is whoever's registered there, not whatever
    // `owner_map.get` resolves the shared node's *parent* to.
    if (sym.flags.s_fn_param) {
        if (f.owner_map.declaredAt(sym.decl)) |owner_local| {
            if (!(SymbolId{ .file = id.file, .local = owner_local }).eql(id)) {
                return .{ .file = id.file, .local = owner_local };
            }
        }
    }
    const owner_local = f.owner_map.get(sym.decl) orelse return null;
    return .{ .file = id.file, .local = owner_local };
}

/// Walks `id`'s owner chain as far as it stays inside `dead_ids`, returning
/// the topmost dead ancestor (or `id` itself if its owner isn't dead).
fn outermostDead(project: *const Project, dead_ids: *const std.AutoHashMapUnmanaged(SymbolId, void), id: SymbolId) SymbolId {
    var outermost = id;
    while (ownerOf(project, outermost)) |owner| {
        if (!dead_ids.contains(owner)) break;
        outermost = owner;
    }
    return outermost;
}

pub const Dead = struct {
    id: SymbolId,
    possible: bool,
    /// Count of dead descendants (nested locals, parameters, enum members,
    /// etc.) folded into this finding rather than reported separately.
    nested: usize = 0,
};
