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
//! - `.public_api`: every `pub` symbol, under `PublicPolicy.root` (library
//!   mode) — see `PublicPolicy` — or, whatever the policy, in a file
//!   outside the analyzed `build.zig`'s own directory, which this project
//!   shares with consumers it can't see (`isSharedDependency`).
//! - `.comptime_block`: every symbol referenced from a container-level
//!   `comptime { ... }` block (`comptime { _ = Foo; }`, the idiom for
//!   forcing analysis of a declaration). Zig evaluates such a block
//!   whenever the container is analyzed, so what it references is used,
//!   even though — like a `test` block — the block has no symbol of its
//!   own for `OwnerMap` to attribute the reference to.
//!
//! - `.test_block`: every symbol referenced from a container-level `test
//!   { ... }` block, collected separately by `buildTestBlockRoots` and
//!   never by `build` — see Phase 37 there.
//!
//! Test code deliberately seeds nothing in `build`. A `test { ... }` block has no
//! symbol identity of its own (see `Builder.zig`'s `test_decl` handling),
//! so `OwnerMap` finds no owner for references inside it and `SymbolGraph`
//! records no edges from it — and that's the intended semantics: a
//! declaration only a test references is dead. `Project` likewise never
//! follows an `@import` written inside a `test` block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");

const Project = @import("Project.zig");
const File = @import("File.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;
const FieldChain = @import("FieldChain.zig");

const Roots = @This();

pub const RootKind = enum { executable_entry, @"export", public_api, comptime_block, test_block };

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
        const shared = isSharedDependency(project, f.path);

        var it = semantic.symbols.iter();
        while (it.next()) |local| {
            const sym = semantic.symbols.get(local);
            if (sym.flags.s_export) {
                try roots.add(gpa, .{ .file = f.id, .local = local }, .@"export");
            }
            if (sym.visibility == .public and (public_policy == .root or shared)) {
                try roots.add(gpa, .{ .file = f.id, .local = local }, .public_api);
            }

            // A reference no declaration owns sits in a container-level
            // block: a `test` (which seeds nothing) or a `comptime` block.
            var ref_it = semantic.symbols.iterReferences(local);
            while (ref_it.next()) |ref| {
                if (f.owner_map.get(ref.node) != null) continue;
                if (isInTestScope(semantic, ref.scope)) continue;
                try roots.addBlockReference(gpa, &f, local, ref.node, .comptime_block);
            }
        }
    }

    return roots;
}

/// Phase 37: the mirror image of `build`'s `.comptime_block` seeding — every
/// symbol a container-level `test { ... }` block references, and everything
/// its chain passes through. On its own this is not a reachability root set:
/// `main` takes reachability over `build`'s roots *plus* these, and the
/// difference between the two runs is exactly the set only test code reaches.
///
/// That set wants reporting, not deleting. A `tmpRoot` helper at the bottom
/// of a production file is the same thing as a whole test-only file — which
/// `Project.isTestOnly` already declines to call an orphan — just without a
/// file of its own to be recognized by.
pub fn buildTestBlockRoots(gpa: Allocator, project: *const Project) Allocator.Error!Roots {
    var roots: Roots = .empty;
    errdefer roots.deinit(gpa);

    for (project.files.items) |f| {
        const semantic = &f.semantic;
        var it = semantic.symbols.iter();
        while (it.next()) |local| {
            var ref_it = semantic.symbols.iterReferences(local);
            while (ref_it.next()) |ref| {
                if (f.owner_map.get(ref.node) != null) continue;
                if (!isInTestScope(semantic, ref.scope)) continue;
                try roots.addBlockReference(gpa, &f, local, ref.node, .test_block);
            }
        }
    }

    return roots;
}

/// Seeds `local` — and every symbol the field chain starting at `ref_node`
/// passes through or lands on — as a root of `kind`. Shared by the
/// `comptime`- and `test`-block passes, which differ only in which scope
/// they accept and what they call the result.
fn addBlockReference(
    self: *Roots,
    gpa: Allocator,
    f: *const File,
    local: Semantic.Symbol.Id,
    ref_node: Semantic.Ast.Node.Index,
    kind: RootKind,
) Allocator.Error!void {
    try self.add(gpa, .{ .file = f.id, .local = local }, kind);
    const semantic = &f.semantic;
    const chain = FieldChain.resolveChain(semantic, semantic, &f.owner_map, local, ref_node, .definite);
    for (chain.visitedSlice()) |through| {
        try self.add(gpa, .{ .file = f.id, .local = through }, kind);
    }
    if (chain.result.symbol != local) {
        try self.add(gpa, .{ .file = f.id, .local = chain.result.symbol }, kind);
    }
}

/// Phase 36: whether `path` sits outside the directory holding the
/// `build.zig` being analyzed — a file this project reaches through a `..`
/// path, and therefore one it shares with projects this run can't see. A
/// monorepo's `sdks/` copy, built into a backend *and* into six demos, is
/// the case in point: judged from the backend alone, everything only the
/// demos call reads as unreachable, and the only way to "fix" that finding
/// is to delete working code. So a shared file's `pub` declarations are
/// treated as external API, exactly as library mode treats the whole
/// project's. Its non-`pub` declarations are still checked normally —
/// nothing outside the file can reach those whatever else builds it.
///
/// Inert when no `build.zig` was loaded at all (`build_graph_dir` empty),
/// which is how the tests drive `Project` directly.
fn isSharedDependency(project: *const Project, path: []const u8) bool {
    const root_dir = project.build_graph_dir;
    if (root_dir.len == 0) return false;
    if (!std.mem.startsWith(u8, path, root_dir)) return true;
    if (path.len == root_dir.len) return false;
    return path[root_dir.len] != std.fs.path.sep;
}

/// True if `scope_id`, or any of its ancestors, was created by a `test`
/// block.
fn isInTestScope(semantic: *const Semantic, scope_id: Semantic.Scope.Id) bool {
    var it = semantic.scopes.iterParents(scope_id);
    while (it.next()) |id| {
        if (semantic.scopes.getScope(id).flags.s_test) return true;
    }
    return false;
}
