//! zigroot CLI.
//!
//! Takes no arguments: looks for a `build.zig` in the current directory,
//! loads every `addExecutable`/`addLibrary`/`addTest` root module it
//! defines as a project root, follows their `@import("*.zig")` chains,
//! scans `.` for `.zig` files that no root ever reaches ("orphan files"),
//! then reports declarations unreachable from any root
//! (`executable_entry`'s `main`, or `export`ed symbols) via `SymbolGraph`
//! reachability (Phase 5) plus cross-file `@import` edges (Phase 6),
//! including `Foo.bar()` (Phase 7) and instance-method calls on a
//! locally-typed variable (Phase 14), both same-file and across an
//! `@import` boundary (Phase 15). A `build.zig` that defines a library
//! and no executable is analyzed in library mode (every `pub` symbol is
//! reachable API); otherwise `pub` alone doesn't make a symbol a root.

const std = @import("std");
const zigroot = @import("zigroot");
const Project = zigroot.Project;

pub fn main() !u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.fs.cwd().access("build.zig", .{}) catch {
        std.debug.print("error: no 'build.zig' in the current directory; zigroot analyzes the project rooted here\n", .{});
        return 1;
    };

    var project: Project = .init(gpa);
    defer project.deinit();

    var had_errors = false;

    project.loadBuildGraph("build.zig") catch |err| {
        std.debug.print("error: failed to load build graph from 'build.zig': {s}\n", .{@errorName(err)});
        had_errors = true;
    };

    if (project.roots.items.len == 0) {
        std.debug.print("error: no roots found ('build.zig' defines no addExecutable/addLibrary/addTest root module)\n", .{});
        return 1;
    }

    const public_policy: zigroot.Roots.PublicPolicy = if (project.build_graph) |bg|
        (if (bg.has_library and !bg.has_executable) .root else .analyze)
    else
        .analyze;

    std.debug.print("loaded {d} file(s) reachable from {d} root(s)\n", .{
        project.files.items.len,
        project.roots.items.len,
    });

    if (project.import_graph.unresolved.items.len > 0) {
        std.debug.print("\n{d} unresolved import(s):\n", .{project.import_graph.unresolved.items.len});
        for (project.import_graph.unresolved.items) |u| {
            const from_path = project.file(u.from).path;
            std.debug.print("  {s}: @import(\"{s}\") [{s}]\n", .{ from_path, u.specifier, @tagName(u.kind) });
        }
    }

    var discovered = project.discoverZigFiles(".") catch |err| {
        std.debug.print("error: failed to scan '.': {s}\n", .{@errorName(err)});
        return 1;
    };
    defer {
        for (discovered.items) |p| gpa.free(p);
        discovered.deinit(gpa);
    }

    var orphans: std.ArrayListUnmanaged([]const u8) = .empty;
    defer orphans.deinit(gpa);
    for (discovered.items) |path| {
        if (!project.isReachable(path)) try orphans.append(gpa, path);
    }

    if (orphans.items.len > 0) {
        std.debug.print("\n{d} orphan file(s) (unreachable from any root):\n", .{orphans.items.len});
        for (orphans.items) |path| {
            std.debug.print("  {s}\n", .{path});
        }
        had_errors = true;
    } else {
        std.debug.print("\nno orphan files under '.'\n", .{});
    }

    var roots = try zigroot.Roots.build(gpa, &project, public_policy);
    defer roots.deinit(gpa);

    var cross_file = try zigroot.Resolver.build(gpa, &project);
    defer cross_file.deinit(gpa);

    var reachability = try zigroot.Reachability.build(gpa, &project, &roots, &cross_file);
    defer reachability.deinit(gpa);

    var dead = try reachability.deadSymbols(gpa, &project);
    defer dead.deinit(gpa);

    var scc = try zigroot.Scc.build(gpa, &project, &cross_file);
    defer scc.deinit(gpa);

    var reported_cycles: std.AutoHashMapUnmanaged(zigroot.Scc.ComponentId, void) = .empty;
    defer reported_cycles.deinit(gpa);

    var dead_count: usize = 0;
    for (dead.items) |d| {
        if (d.possible) continue;
        const name = project.symbol(d.id).name;
        if (name.len == 0) continue;

        if (scc.componentOf(d.id)) |component| {
            if (scc.isCyclic(component)) {
                if (reported_cycles.contains(component)) continue;
                try reported_cycles.put(gpa, component, {});
                dead_count += 1;
                continue;
            }
        }

        dead_count += 1;
    }
    reported_cycles.clearRetainingCapacity();

    if (dead_count > 0) {
        std.debug.print("\n{d} dead declaration(s) (unreachable from any root):\n", .{dead_count});
    }

    var reported: usize = 0;
    for (dead.items) |d| {
        if (d.possible) continue;
        const name = project.symbol(d.id).name;
        if (name.len == 0) continue;

        if (scc.componentOf(d.id)) |component| {
            if (scc.isCyclic(component)) {
                if (reported_cycles.contains(component)) continue;
                try reported_cycles.put(gpa, component, {});
                reported += 1;
                std.debug.print("  cycle of {d} declaration(s), unreachable from any root:\n", .{scc.members(component).len});
                for (scc.members(component)) |member| {
                    const member_name = project.symbol(member).name;
                    if (member_name.len == 0) continue;
                    std.debug.print("    {s}: {s}\n", .{ project.file(member.file).path, member_name });
                }
                continue;
            }
        }

        reported += 1;
        std.debug.print("  {s}: {s}", .{ project.file(d.id.file).path, name });
        if (d.nested > 0) std.debug.print(" (+{d} nested)", .{d.nested});
        std.debug.print("\n", .{});
    }

    if (reported > 0) {
        had_errors = true;
    } else {
        std.debug.print("\nno dead declarations found\n", .{});
    }

    return if (had_errors) 1 else 0;
}
