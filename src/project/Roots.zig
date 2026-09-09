//! Phase 5: declarations that seed reachability, independent of whether
//! anything in the project references them.
//!
//! Populates these kinds automatically:
//! - `executable_entry`: the `main` function declared in one of the
//!   project's `--root` files.
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
//!   test body, same-file or across an `@import` boundary.
//! - `.public_api`: (Phase 8) every `pub` symbol, but only under
//!   `PublicPolicy.root` (library mode) — see `PublicPolicy`.
//!
//! `.configured` names an explicit CLI allowlist a later phase adds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");

const Project = @import("../Project.zig");
const FileId = @import("FileId.zig").FileId;
const SymbolId = @import("SymbolId.zig").SymbolId;
const FieldChain = @import("FieldChain.zig");
const InstanceType = @import("InstanceType.zig");
const Semantic = zlint.Semantic;
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
/// top-level `main`, every `export`ed symbol, every symbol referenced from
/// a `test` block, and (under `PublicPolicy.root`) every `pub` symbol.
pub fn build(gpa: Allocator, project: *const Project, public_policy: PublicPolicy) Allocator.Error!Roots {
    var roots: Roots = .empty;
    errdefer roots.deinit(gpa);

    for (project.roots.items) |file_id| {
        const semantic = &project.file(file_id).semantic;
        if (semantic.symbols.getSymbolNamed("main")) |local| {
            try roots.add(gpa, .{ .file = file_id, .local = local }, .executable_entry);
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
            const instance_ty = InstanceType.resolve(semantic, sym_id);
            const cross_instance = if (instance_ty == null) crossInstanceType(project, f.id, semantic, sym_id) else null;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                if (!isInTestScope(&semantic.scopes, ref.scope)) continue;

                try roots.add(gpa, .{ .file = f.id, .local = sym_id }, .@"test");

                const chain = FieldChain.resolveChain(semantic, semantic, sym_id, ref.node, .definite);
                if (chain.result.symbol != sym_id) {
                    try roots.add(gpa, .{ .file = f.id, .local = chain.result.symbol }, .@"test");
                }
                if (chain.unknown) |unknown| for (unknown.exports) |target| {
                    try roots.add(gpa, .{ .file = f.id, .local = target }, .@"test");
                };

                if (instance_ty) |ty| {
                    const inst_chain = FieldChain.resolveChain(semantic, semantic, ty, ref.node, .possible);
                    if (inst_chain.result.symbol != ty) {
                        try roots.add(gpa, .{ .file = f.id, .local = inst_chain.result.symbol }, .@"test");
                    }
                    if (inst_chain.unknown) |unknown| for (unknown.exports) |target| {
                        try roots.add(gpa, .{ .file = f.id, .local = target }, .@"test");
                    };
                }

                if (cross_instance) |cross| {
                    const target_semantic = &project.file(cross.file).semantic;
                    const inst_chain = FieldChain.resolveChain(semantic, target_semantic, cross.symbol, ref.node, .possible);
                    if (inst_chain.result.symbol != cross.symbol) {
                        try roots.add(gpa, .{ .file = cross.file, .local = inst_chain.result.symbol }, .@"test");
                    }
                    if (inst_chain.unknown) |unknown| for (unknown.exports) |target| {
                        try roots.add(gpa, .{ .file = cross.file, .local = target }, .@"test");
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
fn crossInstanceType(project: *const Project, file_id: FileId, semantic: *const Semantic, sym_id: Semantic.Symbol.Id) ?CrossInstanceType {
    const root = InstanceType.crossFileRoot(semantic, sym_id) orelse return null;
    const target_file = importTarget(project, file_id, root.base) orelse return null;
    const target_semantic = &project.file(target_file).semantic;
    const ty = FieldChain.findExport(target_semantic, FILE_ROOT_SYMBOL, root.field) orelse return null;
    return .{ .file = target_file, .symbol = ty };
}

/// The target file of one of `file_id`'s `@import` edges whose binding
/// symbol is `base`, if any. Mirrors `Resolver.importTarget`.
fn importTarget(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?FileId {
    for (project.import_graph.edges.items) |edge| {
        if (edge.from != file_id) continue;
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
