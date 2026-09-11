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
//!
//! Exit codes: 0 clean, 1 if any orphan file or dead declaration was
//! found, 2 if the project couldn't be loaded or some file has parse
//! errors (its symbol table is partial, so findings can't be trusted).

const std = @import("std");
const zigroot = @import("zigroot");
const Project = zigroot.Project;
const Semantic = zigroot.Semantic;

pub fn main() !u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.fs.cwd().access("build.zig", .{}) catch {
        std.debug.print("error: no 'build.zig' in the current directory; zigroot analyzes the project rooted here\n", .{});
        return 2;
    };

    var project: Project = .init(gpa);
    defer project.deinit();

    var had_findings = false;

    project.loadBuildGraph("build.zig") catch |err| {
        std.debug.print("error: failed to load build graph from 'build.zig': {s}\n", .{@errorName(err)});
        return 2;
    };

    if (project.roots.items.len == 0) {
        std.debug.print("error: no roots found ('build.zig' defines no addExecutable/addLibrary/addTest root module)\n", .{});
        return 2;
    }

    const error_count = project.errorCount();
    if (error_count > 0) {
        std.debug.print("{d} parse error(s); findings below may be incomplete:\n", .{error_count});
        for (project.files.items) |f| {
            for (f.errors.items) |err| {
                if (err.labels.items.len > 0) {
                    const loc = Semantic.Location.fromSpan(f.source, err.labels.items[0].span);
                    std.debug.print("  {s}:{d}:{d}: {s}\n", .{ f.path, loc.line, loc.column, err.message });
                } else {
                    std.debug.print("  {s}: {s}\n", .{ f.path, err.message });
                }
            }
        }
        std.debug.print("\n", .{});
    }

    const public_policy: zigroot.Roots.PublicPolicy = if (project.build_graph) |bg|
        (if (bg.has_library and !bg.has_executable) .root else .analyze)
    else
        .analyze;

    std.debug.print("loaded {d} file(s) reachable from {d} root(s)\n", .{
        project.files.items.len,
        project.roots.items.len,
    });

    var externals: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer externals.deinit(gpa);
    var unresolved_count: usize = 0;
    for (project.import_graph.unresolved.items) |u| {
        switch (u.reason) {
            .external => try externals.put(gpa, u.specifier, {}),
            .unknown_module, .load_failed => unresolved_count += 1,
            .not_a_zig_file => {},
        }
    }

    if (externals.count() > 0) {
        std.debug.print("\n{d} external module(s):", .{externals.count()});
        for (externals.keys()) |name| std.debug.print(" {s}", .{name});
        std.debug.print("\n", .{});
    }

    if (unresolved_count > 0) {
        std.debug.print("\n{d} unresolved import(s):\n", .{unresolved_count});
        for (project.import_graph.unresolved.items) |u| {
            switch (u.reason) {
                .external, .not_a_zig_file => continue,
                .unknown_module, .load_failed => {},
            }
            const from_path = project.file(u.from).path;
            std.debug.print("  {s}: @import(\"{s}\") [{s}]\n", .{ from_path, u.specifier, @tagName(u.reason) });
        }
    }

    var discovered = project.discoverZigFiles(".") catch |err| {
        std.debug.print("error: failed to scan '.': {s}\n", .{@errorName(err)});
        return 2;
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
        had_findings = true;
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
        had_findings = true;
    } else {
        std.debug.print("\nno dead declarations found\n", .{});
    }

    if (error_count > 0) return 2;
    return if (had_findings) 1 else 0;
}
