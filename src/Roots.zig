//! Phase 5: declarations that seed reachability, independent of whether
//! anything in the project references them.
//!
//! Populates these kinds automatically:
//! - `executable_entry`: `main`, `std_options`, and `panic` declared in one
//!   of the project's `--root` files — names the Zig compiler itself looks
//!   for structurally in a root source file, independent of whether
//!   anything in user code references them by name.
//! - `.export`: any symbol with ZLint's `s_export` flag (`export fn`,
//!   `export var`), since those are reachable from outside the compiled
//!   binary regardless of internal references.
//! - `.test`: (Phase 8) any symbol referenced from inside a `test { ... }`
//!   block. ZLint gives `test` blocks no symbol identity of their own (see
//!   `Builder.zig`'s `test_decl` handling), so there's no declaration to
//!   make a root out of directly — instead, every symbol a test body
//!   refers to becomes a root, the same way `main`'s body being reachable
//!   makes everything it calls reachable. `FieldChain.resolveChain` extends
//!   this to `container.member` and `@field(...)` chains a test body
//!   references (Phase 13); `InstanceType` (Phase 14/15) extends it further
//!   to instance-method calls on a locally-typed variable declared in the
//!   test body, same-file or across an `@import` boundary. Phase 20 covers
//!   two more test-body shapes the same reasoning applies to: a reference
//!   inside a `test { ... }` block has no owning symbol (`OwnerMap` finds
//!   none, since the test block itself declares no symbol), so `Resolver`'s
//!   cross-file graph-building — keyed on that owner — skips it entirely;
//!   here the reference is already in hand, so the target is resolved and
//!   rooted directly instead. That covers both a test body referencing an
//!   `@import` binding directly (`const RuleTester = @import("tester.zig");
//!   test { RuleTester.init(...); }`, via `importTarget` +
//!   `FieldChain`/`DynamicField`) and `var runner = RuleTester.init(...);
//!   runner.run(...);` inside the test body itself (via `Resolver`'s
//!   `callInstanceType`, the same call-returns-a-type resolution
//!   `SymbolGraph` edges outside tests already get).
//! - `.public_api`: (Phase 8) every `pub` symbol, but only under
//!   `PublicPolicy.root` (library mode) — see `PublicPolicy`.
//!
//! `.configured` names an explicit CLI allowlist a later phase adds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");

const Project = @import("Project.zig");
const FileId = @import("FileId.zig").FileId;
const SymbolId = @import("SymbolId.zig").SymbolId;
const FieldChain = @import("FieldChain.zig");
const DynamicField = @import("DynamicField.zig");
const InstanceType = @import("InstanceType.zig");
const Resolver = @import("Resolver.zig");
const OwnerMap = @import("OwnerMap.zig");
const Scope = Semantic.Scope;

/// Every file's top-level declarations are exported from this symbol.
/// ZLint's `SemanticBuilder.enterRoot` always creates it first, so its id is
/// always 0. Mirrors `Resolver`'s constant of the same name.
const FILE_ROOT_SYMBOL: Semantic.Symbol.Id = @enumFromInt(0);

const Roots = @This();

pub const RootKind = enum { executable_entry, @"test", @"export", public_api, configured };

/// Whether `pub` alone makes a symbol a root.
///
/// - `.analyze`: `pub` is just an implementation detail (executable mode).
///   The default, since passing `--root` already names the real entry
///   points.
/// - `.root`: every `pub` symbol is a library's external API and therefore
///   always reachable (library mode).
pub const PublicPolicy = enum { root, analyze };

pub const Root = struct {
    symbol: SymbolId,
    kind: RootKind,
};

roots: std.ArrayListUnmanaged(Root) = .empty,

pub const empty: Roots = .{};

pub fn deinit(self: *Roots, gpa: Allocator) void {
    self.roots.deinit(gpa);
    self.* = undefined;
}

fn add(self: *Roots, gpa: Allocator, symbol: SymbolId, kind: RootKind) Allocator.Error!void {
    try self.roots.append(gpa, .{ .symbol = symbol, .kind = kind });
}

/// Collects every automatic root in `project`: each configured root file's
/// top-level `main`/`std_options`/`panic`, every `export`ed symbol, every
/// symbol referenced from a `test` block, and (under `PublicPolicy.root`)
/// every `pub` symbol.
pub fn build(gpa: Allocator, project: *const Project, public_policy: PublicPolicy) Allocator.Error!Roots {
    var roots: Roots = .empty;
    errdefer roots.deinit(gpa);

    const compiler_recognized_names = [_][]const u8{ "main", "std_options", "panic" };
    for (project.roots.items) |file_id| {
        const semantic = &project.file(file_id).semantic;
        for (compiler_recognized_names) |name| {
            if (semantic.symbols.getSymbolNamed(name)) |local| {
                try roots.add(gpa, .{ .file = file_id, .local = local }, .executable_entry);
            }
        }
    }

    for (project.files.items) |f| {
        const semantic = &f.semantic;

        var it = semantic.symbols.iter();
        while (it.next()) |local| {
            const sym = semantic.symbols.get(local);
            if (sym.flags.s_export) {
                try roots.add(gpa, .{ .file = f.id, .local = local }, .@"export");
            }
            if (public_policy == .root and sym.visibility == .public) {
                try roots.add(gpa, .{ .file = f.id, .local = local }, .public_api);
            }
        }

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            // These four resolutions are only ever used inside the
            // `isInTestScope` branch below, so they're computed lazily on
            // the first test-scope reference found (if any) rather than
            // unconditionally per symbol — `importTarget` in particular is
            // otherwise a full-project-import-edges scan paid for every
            // symbol regardless of whether it ever has a test reference.
            var resolved = false;
            var instance_ty: ?Semantic.Symbol.Id = null;
            var cross_instance: ?CrossInstanceType = null;
            var call_instance: ?SymbolId = null;
            var import_target: ?FileId = null;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                if (!isInTestScope(&semantic.scopes, ref.scope)) continue;

                if (!resolved) {
                    instance_ty = InstanceType.resolve(semantic, &f.owner_map, sym_id);
                    cross_instance = if (instance_ty == null) crossInstanceType(project, f.id, semantic, &f.owner_map, sym_id) else null;
                    call_instance = if (instance_ty == null and cross_instance == null) Resolver.callInstanceType(project, f.id, sym_id) else null;
                    import_target = importTarget(project, f.id, sym_id);
                    resolved = true;
                }

                try roots.add(gpa, .{ .file = f.id, .local = sym_id }, .@"test");

                const chain = FieldChain.resolveChain(semantic, semantic, &f.owner_map, sym_id, ref.node, .definite);
                if (chain.result.symbol != sym_id) {
                    try roots.add(gpa, .{ .file = f.id, .local = chain.result.symbol }, .@"test");
                }
                if (chain.unknown) |unknown| for (unknown.exports) |target| {
                    try roots.add(gpa, .{ .file = f.id, .local = target }, .@"test");
                };

                if (instance_ty) |ty| {
                    const inst_chain = FieldChain.resolveChain(semantic, semantic, &f.owner_map, ty, ref.node, .possible);
                    if (inst_chain.result.symbol != ty) {
                        try roots.add(gpa, .{ .file = f.id, .local = inst_chain.result.symbol }, .@"test");
                    }
                    if (inst_chain.unknown) |unknown| for (unknown.exports) |target| {
                        try roots.add(gpa, .{ .file = f.id, .local = target }, .@"test");
                    };
                }

                if (cross_instance) |cross| {
                    const target_file = project.file(cross.file);
                    const inst_chain = FieldChain.resolveChain(semantic, &target_file.semantic, &target_file.owner_map, cross.symbol, ref.node, .possible);
                    if (inst_chain.result.symbol != cross.symbol) {
                        try roots.add(gpa, .{ .file = cross.file, .local = inst_chain.result.symbol }, .@"test");
                    }
                    if (inst_chain.unknown) |unknown| for (unknown.exports) |target| {
                        try roots.add(gpa, .{ .file = cross.file, .local = target }, .@"test");
                    };
                }

                if (call_instance) |call| {
                    const target_file = project.file(call.file);
                    const inst_chain = FieldChain.resolveChain(semantic, &target_file.semantic, &target_file.owner_map, call.local, ref.node, .possible);
                    if (inst_chain.result.symbol != call.local) {
                        try roots.add(gpa, .{ .file = call.file, .local = inst_chain.result.symbol }, .@"test");
                    }
                    if (inst_chain.unknown) |unknown| for (unknown.exports) |target| {
                        try roots.add(gpa, .{ .file = call.file, .local = target }, .@"test");
                    };
                }

                if (import_target) |target_file_id| {
                    const target_file = project.file(target_file_id);
                    const target_semantic = &target_file.semantic;

                    if (FieldChain.fieldAccessName(semantic, ref.node)) |field_name| {
                        if (FieldChain.findExport(target_semantic, &target_file.owner_map, FILE_ROOT_SYMBOL, field_name)) |target_local| {
                            const field_node = semantic.node_links.getParent(ref.node).?;
                            const cross_chain = FieldChain.resolveChain(semantic, target_semantic, &target_file.owner_map, target_local, field_node, .definite);
                            try roots.add(gpa, .{ .file = target_file_id, .local = cross_chain.result.symbol }, .@"test");
                            if (cross_chain.unknown) |unknown| for (unknown.exports) |target| {
                                try roots.add(gpa, .{ .file = target_file_id, .local = target }, .@"test");
                            };
                        }
                    } else if (DynamicField.resolve(semantic, target_semantic, FILE_ROOT_SYMBOL, ref.node)) |resolution| switch (resolution) {
                        .possible => |target_local| {
                            const field_node = semantic.node_links.getParent(ref.node).?;
                            const cross_chain = FieldChain.resolveChain(semantic, target_semantic, &target_file.owner_map, target_local, field_node, .possible);
                            try roots.add(gpa, .{ .file = target_file_id, .local = cross_chain.result.symbol }, .@"test");
                            if (cross_chain.unknown) |unknown| for (unknown.exports) |target| {
                                try roots.add(gpa, .{ .file = target_file_id, .local = target }, .@"test");
                            };
                        },
                        .unknown => |exports| for (exports) |target| {
                            try roots.add(gpa, .{ .file = target_file_id, .local = target }, .@"test");
                        },
                    };
                }
            }
        }
    }

    return roots;
}

const CrossInstanceType = struct { file: FileId, symbol: Semantic.Symbol.Id };

/// `InstanceType.crossFileRoot`, finished: if `sym_id`'s declared type
/// crosses an `@import` boundary (`var s: storage.Widget = ...`), the
/// target file and the symbol its type names there. `null` if
/// `crossFileRoot` found nothing, or its `base` isn't actually one of
/// `file_id`'s `@import` bindings, or the target file has no matching
/// export — same checks `Resolver.buildInstanceTypes` runs, duplicated here
/// since `Roots` needs the answer per-symbol rather than building graph
/// edges from it.
fn crossInstanceType(project: *const Project, file_id: FileId, semantic: *const Semantic, owner_map: *const OwnerMap, sym_id: Semantic.Symbol.Id) ?CrossInstanceType {
    const root = InstanceType.crossFileRoot(semantic, owner_map, sym_id) orelse return null;
    const target_file_id = importTarget(project, file_id, root.base) orelse return null;
    const target_file = project.file(target_file_id);
    const ty = FieldChain.findExport(&target_file.semantic, &target_file.owner_map, FILE_ROOT_SYMBOL, root.field) orelse return null;
    return .{ .file = target_file_id, .symbol = ty };
}

/// The target file of one of `file_id`'s `@import` edges whose binding
/// symbol is `base`, if any. Mirrors `Resolver.importTarget`.
fn importTarget(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?FileId {
    for (project.import_graph.edgesFrom(file_id)) |edge| {
        const binding = project.file(edge.from).owner_map.get(edge.node) orelse continue;
        if (binding == base) return edge.to;
    }
    return null;
}

/// True if `scope_id`, or any of its ancestors, was created by a `test`
/// block.
fn isInTestScope(tree: *const Scope.Tree, scope_id: Scope.Id) bool {
    var it = tree.iterParents(scope_id);
    while (it.next()) |id| {
        if (tree.getScope(id).flags.s_test) return true;
    }
    return false;
}
