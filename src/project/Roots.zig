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
//!   makes everything it calls reachable.
//! - `.public_api`: (Phase 8) every `pub` symbol, but only under
//!   `PublicPolicy.root` (library mode) — see `PublicPolicy`.
//!
//! `.configured` names an explicit CLI allowlist a later phase adds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");

const Project = @import("../Project.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;
const FieldChain = @import("FieldChain.zig");
const Scope = zlint.Semantic.Scope;

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
            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                if (!isInTestScope(&semantic.scopes, ref.scope)) continue;

                try roots.add(gpa, .{ .file = f.id, .local = sym_id }, .@"test");

                const chained = FieldChain.resolve(semantic, semantic, sym_id, ref.node);
                if (chained.symbol != sym_id) {
                    try roots.add(gpa, .{ .file = f.id, .local = chained.symbol }, .@"test");
                }
            }
        }
    }

    return roots;
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
