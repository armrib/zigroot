//! A whole-project view built on top of ZLint's per-file `Semantic`
//! analysis: file discovery, `@import("file.zig")` resolution, and
//! (Phase 1) unreachable-file detection.
//!
//! ZLint's `Semantic` deliberately only understands one file at a time
//! ("program" in its docs means "a single parsed file", not a linked
//! binary or library). `Project` is the layer above it that stitches
//! per-file `Semantic`s together into a project-wide graph; it does not
//! modify or fork ZLint's semantic analysis.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");

const FileId = @import("FileId.zig").FileId;
const File = @import("File.zig");
const ImportGraph = @import("ImportGraph.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;
const BuildGraph = @import("BuildGraph.zig");

const Project = @This();

gpa: Allocator,
files: std.ArrayListUnmanaged(File) = .empty,
/// Canonical absolute path -> FileId. Keys borrow `files[..].path`.
by_path: std.StringHashMapUnmanaged(FileId) = .empty,
roots: std.ArrayListUnmanaged(FileId) = .empty,
import_graph: ImportGraph = .empty,
/// Named-module imports (`@import("some_mod")`) that `build_graph`
/// resolves to a local file, keyed by the `build.zig`'s directory. `null`
/// until `loadBuildGraph` is called; named-module imports stay unresolved
/// without it.
build_graph: ?BuildGraph = null,
build_graph_dir: []const u8 = "",

pub fn init(gpa: Allocator) Project {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Project) void {
    for (self.files.items) |*f| f.deinit(self.gpa);
    self.files.deinit(self.gpa);
    self.by_path.deinit(self.gpa);
    self.roots.deinit(self.gpa);
    self.import_graph.deinit(self.gpa);
    if (self.build_graph) |*bg| bg.deinit(self.gpa);
    if (self.build_graph_dir.len > 0) self.gpa.free(self.build_graph_dir);
    self.* = undefined;
}

/// Parses `build_zig_path` and records its local module graph, so
/// `@import("name")` module specifiers it defines via
/// `b.createModule(...)` + `.addImport("name", ...)` resolve to files
/// instead of being reported unresolved. Must be called before `addRoot`
/// for roots that use those imports.
///
/// Also follows local `const x = @import("relative/file.zig");` bindings
/// transitively into sibling files that `build_zig_path` delegates its
/// actual module wiring to (a thin top-level aggregator calling into a
/// per-app `build.zig` helper, say), merging every file's
/// `createModule`/`addModule`/`addImport` shapes into the same graph. Every
/// `b.path(...)` string collected this way stays resolved against
/// `build_zig_path`'s own directory — the real build root, since `b.path`
/// always resolves relative to the top-level build script regardless of
/// which file the call is lexically written in — not the directory of
/// whichever file it was found in.
pub fn loadBuildGraph(self: *Project, build_zig_path: []const u8) !void {
    const canonical = try self.canonicalize(build_zig_path);
    defer self.gpa.free(canonical);

    self.build_graph_dir = try self.gpa.dupe(u8, std.fs.path.dirname(canonical) orelse ".");
    errdefer {
        self.gpa.free(self.build_graph_dir);
        self.build_graph_dir = "";
    }

    var graph: BuildGraph = .empty;
    errdefer graph.deinit(self.gpa);

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        visited.deinit(self.gpa);
    }

    try self.scanBuildFile(&graph, &visited, canonical);

    self.build_graph = graph;
}

/// Scans one `build.zig` (or a file it locally `@import`s) into `graph`,
/// then recurses into every local-file `@import` it found — see
/// `loadBuildGraph`. `visited` guards against re-scanning the same file
/// twice (an import cycle, or the same helper imported from two places).
fn scanBuildFile(
    self: *Project,
    graph: *BuildGraph,
    visited: *std.StringHashMapUnmanaged(void),
    canonical: []const u8,
) anyerror!void {
    if (visited.contains(canonical)) return;
    try visited.put(self.gpa, try self.gpa.dupe(u8, canonical), {});

    const source = try File.readFileSentinel(self.gpa, canonical);
    defer self.gpa.free(source);

    var file_imports: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (file_imports.items) |p| self.gpa.free(p);
        file_imports.deinit(self.gpa);
    }

    try BuildGraph.parseInto(self.gpa, graph, source, &file_imports);

    const dir = std.fs.path.dirname(canonical) orelse ".";
    for (file_imports.items) |rel_path| {
        const target_path = std.fs.path.resolve(self.gpa, &.{ dir, rel_path }) catch continue;
        defer self.gpa.free(target_path);
        const target_canonical = self.canonicalize(target_path) catch continue;
        defer self.gpa.free(target_canonical);

        try self.scanBuildFile(graph, visited, target_canonical);
    }
}

pub fn file(self: *const Project, id: FileId) *const File {
    return &self.files.items[id.index()];
}

/// Resolves a project-wide `SymbolId` to the ZLint symbol it identifies.
pub fn symbol(self: *const Project, id: SymbolId) *const zlint.Semantic.Symbol {
    return self.file(id.file).semantic.symbols.get(id.local);
}

/// True iff some configured root transitively imports `path`. Only
/// meaningful for paths that were passed through `resolvePath` (or that
/// came out of `discoverZigFiles`), since it compares canonical paths.
pub fn isReachable(self: *const Project, canonical_path: []const u8) bool {
    return self.by_path.contains(canonical_path);
}

/// Adds `path` as a project root: loads it, parses it, and recursively
/// follows its `@import("*.zig")` chain. Returns the root's `FileId`.
pub fn addRoot(self: *Project, path: []const u8) !FileId {
    const id = try self.loadRecursive(path);
    try self.roots.append(self.gpa, id);
    return id;
}

/// Loads `path` (if not already loaded), records its file-import edges,
/// and recurses into each resolvable `@import("*.zig")`. Returns the
/// existing or newly-created `FileId`.
fn loadRecursive(self: *Project, path: []const u8) anyerror!FileId {
    const canonical = try self.canonicalize(path);
    defer self.gpa.free(canonical);

    if (self.by_path.get(canonical)) |existing| return existing;

    const id = FileId.fromIndex(self.files.items.len);
    var loaded = try File.load(self.gpa, id, canonical);
    errdefer loaded.deinit(self.gpa);

    try self.files.append(self.gpa, loaded);
    try self.by_path.put(self.gpa, self.files.items[id.index()].path, id);

    const dir = std.fs.path.dirname(canonical) orelse ".";
    const imports = self.files.items[id.index()].semantic.modules.imports.items;
    for (imports) |entry| {
        switch (entry.kind) {
            .module => {
                if (try self.resolveViaBuildGraph(id, entry)) continue;
                try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.specifier, ".zig")) {
                    try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node);
                    continue;
                }

                // A build-registered module name always wins over a
                // same-named sibling file — matches real @import
                // semantics, where the compilation's module table is
                // consulted before any filesystem-relative lookup.
                if (try self.resolveViaBuildGraph(id, entry)) continue;

                const target_path = std.fs.path.resolve(self.gpa, &.{ dir, entry.specifier }) catch {
                    try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node);
                    continue;
                };
                defer self.gpa.free(target_path);

                const target_id = self.loadRecursive(target_path) catch {
                    try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node);
                    continue;
                };
                try self.import_graph.addEdge(self.gpa, id, target_id, entry.node);
            },
        }
    }

    return id;
}

/// If `entry.specifier` names a `build_graph`-registered module, loads
/// every candidate root file it resolves to, records an edge for each,
/// and returns `true`. Returns `false` (without touching `import_graph`)
/// if there's no `build_graph` or it doesn't know `entry.specifier`,
/// leaving the caller to fall back to its own resolution or mark the
/// import unresolved.
fn resolveViaBuildGraph(self: *Project, id: FileId, entry: anytype) !bool {
    const build_graph = self.build_graph orelse return false;
    const rel_paths = build_graph.resolve(entry.specifier) orelse return false;

    // More than one candidate means the scan couldn't tell which branch
    // of a conditional the build script actually takes (see
    // BuildGraph.zig); treat every candidate as reachable rather than
    // guessing.
    var resolved_any = false;
    for (rel_paths) |rel_path| {
        const target_path = std.fs.path.resolve(self.gpa, &.{ self.build_graph_dir, rel_path }) catch continue;
        defer self.gpa.free(target_path);

        const target_id = self.loadRecursive(target_path) catch continue;
        try self.import_graph.addEdge(self.gpa, id, target_id, entry.node);
        resolved_any = true;
    }
    if (!resolved_any) {
        try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node);
    }
    return true;
}

fn canonicalize(self: *Project, path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(self.gpa, path);
}

/// Recursively finds every `*.zig` file under `dir` (skipping `.git`,
/// `zig-cache`, `zig-out`, and `vendor`), for orphan-file detection: any
/// discovered path that isn't a key of `by_path` after all roots have been
/// loaded was never reached by `@import` from a configured root.
///
/// Caller owns the returned list and each path in it.
pub fn discoverZigFiles(self: *Project, dir: []const u8) !std.ArrayListUnmanaged([]u8) {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |p| self.gpa.free(p);
        out.deinit(self.gpa);
    }

    var root_dir = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer root_dir.close();

    var walker = try root_dir.walk(self.gpa);
    defer walker.deinit();

    const skip_dirs = [_][]const u8{ ".git", "zig-cache", "zig-out", "vendor" };

    walk: while (try walker.next()) |entry| {
        var it = std.mem.tokenizeScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |component| {
            for (skip_dirs) |skip| {
                if (std.mem.eql(u8, component, skip)) continue :walk;
            }
        }

        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full = try std.fs.path.join(self.gpa, &.{ dir, entry.path });
        defer self.gpa.free(full);
        const canonical = try self.canonicalize(full);
        try out.append(self.gpa, canonical);
    }

    return out;
}
