//! zigroot CLI.
//!
//! Loads one or more project roots, follows their `@import("*.zig")`
//! chains, scans a directory for `.zig` files that no root ever reaches
//! ("orphan files"), then reports declarations unreachable from any root
//! (`executable_entry`'s `main`, or `export`ed symbols) via `SymbolGraph`
//! reachability (Phase 5) plus cross-file `@import` edges (Phase 6). Only
//! the `binding.member` shape resolves across files so far; `Foo.bar()`
//! and instance-method calls are Phase 7+, so a symbol only reached that
//! way is still reported dead here.

const std = @import("std");
const zigroot = @import("zigroot");
const Project = zigroot.Project;

const Options = struct {
    roots: std.ArrayListUnmanaged([]const u8) = .empty,
    scan_dir: []const u8 = ".",

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
        } else {
            std.debug.print("error: unrecognized argument '{s}'\n", .{arg});
            return 1;
        }
    }

    if (opts.roots.items.len == 0) {
        std.debug.print(
            \\usage: zigroot --root <file.zig> [--root <file.zig> ...] [--dir <path>]
            \\
            \\  --root  a project entry point; followed transitively through
            \\          @import("*.zig")
            \\  --dir   directory to scan for orphan .zig files (default: ".")
            \\
        , .{});
        return 1;
    }

    var project: Project = .init(gpa);
    defer project.deinit();

    var had_errors = false;
    for (opts.roots.items) |root| {
        _ = project.addRoot(root) catch |err| {
            std.debug.print("error: failed to load root '{s}': {s}\n", .{ root, @errorName(err) });
            had_errors = true;
            continue;
        };
    }

    std.debug.print("loaded {d} file(s) reachable from {d} root(s)\n", .{
        project.files.items.len,
        opts.roots.items.len,
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

    var roots = try zigroot.Roots.build(gpa, &project);
    defer roots.deinit(gpa);

    var cross_file = try zigroot.Resolver.build(gpa, &project);
    defer cross_file.deinit(gpa);

    var reachability = try zigroot.Reachability.build(gpa, &project, &roots, &cross_file);
    defer reachability.deinit(gpa);

    var dead = try reachability.deadSymbols(gpa, &project);
    defer dead.deinit(gpa);

    if (dead.items.len > 0) {
        std.debug.print("\n{d} dead declaration(s) (unreachable from any root):\n", .{dead.items.len});
        for (dead.items) |id| {
            const sym = project.symbol(id);
            if (sym.name.len == 0) continue;
            std.debug.print("  {s}: {s}\n", .{ project.file(id.file).path, sym.name });
        }
        had_errors = true;
    } else {
        std.debug.print("\nno dead declarations found\n", .{});
    }

    return if (had_errors) 1 else 0;
}
