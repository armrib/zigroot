//! Phase 5: declarations that seed reachability, independent of whether
//! anything in the project references them.
//!
//! MVP populates two kinds automatically:
//! - `executable_entry`: the `main` function declared in one of the
//!   project's `--root` files.
//! - `.export`: any symbol with ZLint's `s_export` flag (`export fn`,
//!   `export var`), since those are reachable from outside the compiled
//!   binary regardless of internal references.
//!
//! The remaining `RootKind` values name roots later phases add (`test`
//! blocks and `pub`-as-library-API in Phase 8, an explicit CLI allowlist)
//! so `Reachability`'s output already carries the right shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Project = @import("../Project.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

const Roots = @This();

pub const RootKind = enum { executable_entry, @"test", @"export", public_api, configured };

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
/// top-level `main`, plus every `export`ed symbol across all loaded files.
pub fn build(gpa: Allocator, project: *const Project) Allocator.Error!Roots {
    var roots: Roots = .empty;
    errdefer roots.deinit(gpa);

    for (project.roots.items) |file_id| {
        const semantic = &project.file(file_id).semantic;
        if (semantic.symbols.getSymbolNamed("main")) |local| {
            try roots.add(gpa, .{ .file = file_id, .local = local }, .executable_entry);
        }
    }

    for (project.files.items) |f| {
        var it = f.semantic.symbols.iter();
        while (it.next()) |local| {
            if (f.semantic.symbols.get(local).flags.s_export) {
                try roots.add(gpa, .{ .file = f.id, .local = local }, .@"export");
            }
        }
    }

    return roots;
}
