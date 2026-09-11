//! Declarations that seed reachability, independent of whether anything
//! in the project references them.
//!
//! Populates these kinds automatically:
//! - `executable_entry`: `main`, `std_options`, and `panic` declared at
//!   the top level of one of the project's root files — names the Zig
//!   compiler itself looks for structurally in a root source file,
//!   independent of whether anything in user code references them by name.
//! - `.export`: any symbol with ZLint's `s_export` flag (`export fn`,
//!   `export var`), since those are reachable from outside the compiled
//!   binary regardless of internal references.
//! - `.public_api`: every `pub` symbol, but only under `PublicPolicy.root`
//!   (library mode) — see `PublicPolicy`.
//!
//! Test code deliberately seeds nothing. A `test { ... }` block has no
//! symbol identity of its own (see `Builder.zig`'s `test_decl` handling),
//! so `OwnerMap` finds no owner for references inside it and `SymbolGraph`
//! records no edges from it — and that's the intended semantics: a
//! declaration only a test references is dead. `Project` likewise never
//! follows an `@import` written inside a `test` block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");

const Project = @import("Project.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

const Roots = @This();

pub const RootKind = enum { executable_entry, @"export", public_api };

/// Whether `pub` alone makes a symbol a root.
///
/// - `.analyze`: `pub` is just visibility (executable mode): only `main`
///   and friends, `export`s, and what they reach count.
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

/// Collects every automatic root in `project`: each root file's top-level
/// `main`/`std_options`/`panic`, every `export`ed symbol, and (under
/// `PublicPolicy.root`) every `pub` symbol.
pub fn build(gpa: Allocator, project: *const Project, public_policy: PublicPolicy) Allocator.Error!Roots {
    var roots: Roots = .empty;
    errdefer roots.deinit(gpa);

    // The compiler looks these up as *top-level* declarations of the root
    // source file, so only a binding in the file's root scope counts — a
    // parameter or local that happens to be named `main` earlier in the
    // file is not the entry point.
    const compiler_recognized_names = [_][]const u8{ "main", "std_options", "panic" };
    for (project.roots.items) |file_id| {
        const semantic = &project.file(file_id).semantic;
        for (compiler_recognized_names) |name| {
            if (semantic.getBinding(Semantic.ROOT_SCOPE_ID, name)) |local| {
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
    }

    return roots;
}
