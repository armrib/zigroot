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
const Report = zigroot.Report;

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
                const rel = relativePath(project.build_graph_dir, f.path);
                if (err.labels.items.len > 0) {
                    const loc = Semantic.Location.fromSpan(f.source, err.labels.items[0].span);
                    std.debug.print("  {s}:{d}:{d}: {s}\n", .{ rel, loc.line, loc.column, err.message });
                } else {
                    std.debug.print("  {s}: {s}\n", .{ rel, err.message });
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
            const from_path = relativePath(project.build_graph_dir, project.file(u.from).path);
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
    var test_only: std.ArrayListUnmanaged([]const u8) = .empty;
    defer test_only.deinit(gpa);
    for (discovered.items) |path| {
        if (project.isReachable(path)) continue;
        if (project.isTestOnly(path)) {
            try test_only.append(gpa, path);
        } else {
            try orphans.append(gpa, path);
        }
    }

    if (test_only.items.len > 0) {
        std.debug.print("\n{d} test-only file(s) (not analyzed; test code doesn't count as use):\n", .{test_only.items.len});
        for (test_only.items) |path| {
            std.debug.print("  {s}\n", .{relativePath(project.build_graph_dir, path)});
        }
    }

    if (orphans.items.len > 0) {
        std.debug.print("\n{d} orphan file(s) (unreachable from any root):\n", .{orphans.items.len});
        for (orphans.items) |path| {
            std.debug.print("  {s}\n", .{relativePath(project.build_graph_dir, path)});
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

    // Phase 37: the same reachability walk with `test { ... }` blocks added
    // as roots. Whatever this reaches that `reachability` did not is reached
    // only from test code.
    var test_roots = try zigroot.Roots.buildTestBlockRoots(gpa, &project);
    defer test_roots.deinit(gpa);
    try test_roots.roots.appendSlice(gpa, roots.roots.items);
    var test_reachable = try zigroot.Reachability.build(gpa, &project, &test_roots, &cross_file);
    defer test_reachable.deinit(gpa);

    var findings = try Report.collect(gpa, &project, dead.items, &scc, project.build_graph_dir, &test_reachable);
    defer Report.deinit(&findings, gpa);

    var counts = std.EnumArray(Report.Class, usize).initFill(0);
    for (findings.items) |f| counts.getPtr(f.class).* += 1;

    if (counts.get(.dead) > 0) {
        std.debug.print("\n{d} dead declaration(s) (unreachable from any root):\n", .{counts.get(.dead)});
        Report.printGrouped(&project, findings.items, .dead);
        had_findings = true;
    } else {
        std.debug.print("\nno dead declarations found\n", .{});
    }

    if (counts.get(.test_only) > 0) {
        std.debug.print("\n{d} test-only declaration(s) (reached only from test code, not from any root):\n", .{counts.get(.test_only)});
        Report.printGrouped(&project, findings.items, .test_only);
    }

    if (counts.get(.possible) > 0) {
        std.debug.print("\n{d} possibly dead declaration(s) (only reached through a runtime-named @field(...)):\n", .{counts.get(.possible)});
        Report.printGrouped(&project, findings.items, .possible);
    }

    if (error_count > 0) return 2;
    return if (had_findings) 1 else 0;
}

/// `path` with the `base_dir` prefix stripped, when it lies under it
/// (both canonical); the full path otherwise. No allocation, so usable
/// straight from a print.
fn relativePath(base_dir: []const u8, path: []const u8) []const u8 {
    if (path.len > base_dir.len and std.mem.startsWith(u8, path, base_dir) and path[base_dir.len] == std.fs.path.sep) {
        return path[base_dir.len + 1 ..];
    }
    return path;
}
