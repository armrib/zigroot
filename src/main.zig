//! zigroot CLI.
//!
//! Loads one or more project roots, follows their `@import("*.zig")`
//! chains, scans a directory for `.zig` files that no root ever reaches
//! ("orphan files"), then reports declarations unreachable from any root
//! (`executable_entry`'s `main`, or `export`ed symbols) via `SymbolGraph`
//! reachability (Phase 5) plus cross-file `@import` edges (Phase 6),
//! including `Foo.bar()` (Phase 7) and instance-method calls on a
//! locally-typed variable (Phase 14), both same-file and across an
//! `@import` boundary (Phase 15).

const std = @import("std");
const zigroot = @import("zigroot");
const Project = zigroot.Project;

const Options = struct {
    roots: std.ArrayListUnmanaged([]const u8) = .empty,
    scan_dir: []const u8 = ".",
    public_policy: zigroot.Roots.PublicPolicy = .analyze,
    include_possible: bool = false,
    build_zig: ?[]const u8 = null,

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        self.roots.deinit(gpa);
        self.* = undefined;
    }
};

pub fn main() !u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    var opts: Options = .{};
    defer opts.deinit(gpa);

    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            const root = args.next() orelse {
                std.debug.print("error: --root requires a path argument\n", .{});
                return 1;
            };
            try opts.roots.append(gpa, root);
        } else if (std.mem.eql(u8, arg, "--dir")) {
            opts.scan_dir = args.next() orelse {
                std.debug.print("error: --dir requires a path argument\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--library")) {
            opts.public_policy = .root;
        } else if (std.mem.eql(u8, arg, "--include-possible")) {
            opts.include_possible = true;
        } else if (std.mem.eql(u8, arg, "--build-zig")) {
            opts.build_zig = args.next() orelse {
                std.debug.print("error: --build-zig requires a path argument\n", .{});
                return 1;
            };
        } else {
            std.debug.print("error: unrecognized argument '{s}'\n", .{arg});
            return 1;
        }
    }

    // No explicit `--root`/`--build-zig`: only auto-run against a
    // `build.zig` in the current directory (its `addExecutable`/
    // `addLibrary`/`addTest` root modules become the roots); otherwise
    // there's nothing to derive roots from, and `--root` is required.
    if (opts.roots.items.len == 0 and opts.build_zig == null) {
        std.fs.cwd().access("build.zig", .{}) catch {
            std.debug.print(
                \\usage: zigroot --root <file.zig> [--root <file.zig> ...] [--dir <path>]
                \\
                \\  --root     a project entry point; followed transitively through
                \\             @import("*.zig")
                \\  --dir      directory to scan for orphan .zig files (default: ".")
                \\  --library  treat every `pub` symbol as reachable library API
                \\             (default: executable mode, where `pub` alone
                \\             doesn't make a symbol a root)
                \\  --include-possible
                \\             also report declarations only reachable through
                \\             an unresolved dynamic access (e.g. `@field(Foo,
                \\             name)` with a runtime name) as dead, instead of
                \\             giving them the benefit of the doubt
                \\  --build-zig <build.zig>
                \\             resolve named-module @import(...)s (e.g.
                \\             @import("storage")) that build.zig wires up via
                \\             b.createModule(...) + .addImport(...), instead
                \\             of leaving them unresolved
                \\
                \\With no --root and no --build-zig, a 'build.zig' in the
                \\current directory is used automatically.
                \\
            , .{});
            return 1;
        };
        opts.build_zig = "build.zig";
    }

    var project: Project = .init(gpa);
    defer project.deinit();

    var had_errors = false;

    if (opts.build_zig) |build_zig_path| {
        project.loadBuildGraph(build_zig_path) catch |err| {
            std.debug.print("error: failed to load build graph from '{s}': {s}\n", .{ build_zig_path, @errorName(err) });
            had_errors = true;
        };
    }

    for (opts.roots.items) |root| {
        _ = project.addRoot(root) catch |err| {
            std.debug.print("error: failed to load root '{s}': {s}\n", .{ root, @errorName(err) });
            had_errors = true;
            continue;
        };
    }

    if (project.roots.items.len == 0) {
        std.debug.print("error: no roots found (pass --root explicitly, or run from a directory whose build.zig defines addExecutable/addLibrary/addTest root modules)\n", .{});
        return 1;
    }

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

    var discovered = project.discoverZigFiles(opts.scan_dir) catch |err| {
        std.debug.print("error: failed to scan '{s}': {s}\n", .{ opts.scan_dir, @errorName(err) });
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
        std.debug.print("\nno orphan files under '{s}'\n", .{opts.scan_dir});
    }

    var roots = try zigroot.Roots.build(gpa, &project, opts.public_policy);
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
        if (d.possible and !opts.include_possible) continue;
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
        if (d.possible and !opts.include_possible) continue;
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
        if (d.possible) std.debug.print(" (possible: only reached via an unresolved dynamic access)", .{});
        std.debug.print("\n", .{});
    }

    if (reported > 0) {
        had_errors = true;
    } else {
        std.debug.print("\nno dead declarations found\n", .{});
    }

    return if (had_errors) 1 else 0;
}
