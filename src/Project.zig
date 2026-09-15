//! A whole-project view built on top of ZLint's per-file `Semantic`
//! analysis: file discovery, `@import("file.zig")` resolution, and
//! (Phase 1) unreachable-file detection.
//!
//! Test code doesn't count as use. An `@import` written inside a `test {
//! ... }` block is not followed into `files`: the target (and everything
//! it in turn imports) is a *test-only file*, recorded in
//! `test_only_files` but never analyzed, so a declaration only a test
//! reaches is dead and a file only a test reaches is neither an orphan nor
//! a source of findings. `b.addTest` root modules get the same treatment
//! (`addTestRoot`): they're loaded only to classify their import closure.
//!
//! ZLint's `Semantic` deliberately only understands one file at a time
//! ("program" in its docs means "a single parsed file", not a linked
//! binary or library). `Project` is the layer above it that stitches
//! per-file `Semantic`s together into a project-wide graph; it does not
//! modify or fork ZLint's semantic analysis.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");

const FileId = @import("FileId.zig").FileId;
const File = @import("File.zig");
const ImportGraph = @import("ImportGraph.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;
const BuildGraph = @import("BuildGraph.zig");
const ZonFile = @import("ZonFile.zig");

const Project = @This();

gpa: Allocator,
files: std.ArrayListUnmanaged(File) = .empty,
/// Canonical absolute path -> FileId. Keys borrow `files[..].path`.
by_path: std.StringHashMapUnmanaged(FileId) = .empty,
roots: std.ArrayListUnmanaged(FileId) = .empty,
import_graph: ImportGraph = .empty,
/// Canonical paths of every `.zig` file reachable only through a test
/// (`@import` inside a `test` block, or a `b.addTest` root module) and
/// nothing else — see the module doc. Never loaded into `files`. Owned.
test_only_files: std.StringHashMapUnmanaged(void) = .empty,
/// `@import`s found inside `test` blocks of analyzed files, deferred
/// until every analysis root is loaded (an analysis root loaded later may
/// still reach the same file for real). Resolved absolute paths. Owned.
pending_test_imports: std.ArrayListUnmanaged([]const u8) = .empty,
/// Named-module imports (`@import("some_mod")`) that `build_graph`
/// resolves to a local file, keyed by the `build.zig`'s directory. `null`
/// until `loadBuildGraph` is called; named-module imports stay unresolved
/// without it.
build_graph: ?BuildGraph = null,
build_graph_dir: []const u8 = "",
/// The `build.zig.zon` next to the loaded `build.zig`, if there was one:
/// its dependency names are external modules, and its path dependencies
/// are excluded from `discoverZigFiles`. Empty until `loadBuildGraph`.
zon: ZonFile = .empty,
/// Canonical paths of the `build.zig` and every file it pulls in (local
/// `@import`s and cross-file helpers) while `loadBuildGraph` scans it.
/// Build scripts are the build's own roots, never `@import`ed by project
/// code, so `isReachable` treats them as reached rather than orphans.
/// Owned.
build_files: std.StringHashMapUnmanaged(void) = .empty,
/// Canonical directories `discoverZigFiles` skips on top of the built-in
/// list: every `.path` dependency of `zon`, resolved against
/// `build_graph_dir`. Owned.
excluded_dirs: std.ArrayListUnmanaged([]const u8) = .empty,

pub fn init(gpa: Allocator) Project {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Project) void {
    for (self.files.items) |*f| f.deinit(self.gpa);
    self.files.deinit(self.gpa);
    self.by_path.deinit(self.gpa);
    self.roots.deinit(self.gpa);
    self.import_graph.deinit(self.gpa);
    var to_it = self.test_only_files.keyIterator();
    while (to_it.next()) |k| self.gpa.free(k.*);
    self.test_only_files.deinit(self.gpa);
    for (self.pending_test_imports.items) |p| self.gpa.free(p);
    self.pending_test_imports.deinit(self.gpa);
    if (self.build_graph) |*bg| bg.deinit(self.gpa);
    if (self.build_graph_dir.len > 0) self.gpa.free(self.build_graph_dir);
    self.zon.deinit(self.gpa);
    var bf_it = self.build_files.keyIterator();
    while (bf_it.next()) |k| self.gpa.free(k.*);
    self.build_files.deinit(self.gpa);
    for (self.excluded_dirs.items) |d| self.gpa.free(d);
    self.excluded_dirs.deinit(self.gpa);
    self.* = undefined;
}

/// Number of parse/semantic diagnostics across every loaded file. Any
/// non-zero count means some file's symbol table is partial and its
/// findings can't be trusted.
pub fn errorCount(self: *const Project) usize {
    var n: usize = 0;
    for (self.files.items) |f| n += f.errors.items.len;
    return n;
}

/// Whether `@import(name)` (a `.module` specifier) names something the
/// project doesn't own: the compiler-provided `std`/`builtin`/`root`, a
/// `build.zig.zon` dependency, or a name `build.zig` binds to a
/// `b.dependency(...)` module. Such imports are reachability sinks — nothing
/// in them can make a project declaration reachable — and never a
/// configuration gap.
pub fn isExternalModule(self: *const Project, name: []const u8) bool {
    const builtin_modules = [_][]const u8{ "std", "builtin", "root" };
    for (builtin_modules) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    if (self.zon.isDependency(name)) return true;
    if (self.build_graph) |bg| {
        if (bg.isExternal(name)) return true;
    }
    return false;
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

    // Shared across the whole recursive scan (not per-file): a cross-file
    // helper call (`vendor.yamlModule(...)`) may need a file that hasn't
    // been scanned as part of the local-@import chain `visited`/`graph`
    // tracks yet — e.g. a helper file only ever referenced this way, never
    // itself `@import`ed by another file already in the chain. Loaded
    // lazily and cached here so the same helper file isn't re-parsed for
    // every call site that names it.
    var helper_cache: HelperFileCache = .empty;
    defer helper_cache.deinit(self.gpa);

    try self.scanBuildFile(&graph, &visited, &helper_cache, canonical);

    var visited_it = visited.keyIterator();
    while (visited_it.next()) |k| try self.noteBuildFile(k.*);
    var helper_it = helper_cache.entries.keyIterator();
    while (helper_it.next()) |k| try self.noteBuildFile(k.*);

    self.build_graph = graph;

    try self.loadZon();

    // Every `addExecutable`/`addLibrary`/`addModule` root module is an
    // analysis root: load each as if it were passed explicitly so the run
    // reaches an executable's `main` (or a library's exports). Best-effort:
    // a path that fails to resolve or load is silently skipped, same as any
    // other best-effort result of this syntactic scan.
    for (graph.exe_roots.items) |rel_path| {
        const target_path = std.fs.path.resolve(self.gpa, &.{ self.build_graph_dir, rel_path }) catch continue;
        defer self.gpa.free(target_path);
        _ = self.addRoot(target_path) catch continue;
    }

    // Each `b.addTest` target is its own root module, never `@import`ed
    // from anywhere, and test code doesn't count as use — so it seeds no
    // roots and isn't analyzed. It's loaded only so it (and whatever it
    // imports that nothing else does) is classified test-only instead of
    // orphaned. Must come after the analysis roots: a file both reach is
    // an ordinary analyzed file.
    for (graph.test_roots.items) |rel_path| {
        const target_path = std.fs.path.resolve(self.gpa, &.{ self.build_graph_dir, rel_path }) catch continue;
        defer self.gpa.free(target_path);
        self.addTestRoot(target_path) catch continue;
    }

    try self.resolveTestImports();
    try self.loadTestOnlyFiles();
}

fn noteBuildFile(self: *Project, canonical: []const u8) !void {
    if (self.build_files.contains(canonical)) return;
    const key = try self.gpa.dupe(u8, canonical);
    errdefer self.gpa.free(key);
    try self.build_files.put(self.gpa, key, {});
}

/// Reads the `build.zig.zon` beside the loaded `build.zig`, if any, into
/// `zon`, and resolves its path dependencies into `excluded_dirs`. A
/// missing or unreadable manifest is not an error: the project just has no
/// declared dependencies.
fn loadZon(self: *Project) !void {
    const zon_path = try std.fs.path.join(self.gpa, &.{ self.build_graph_dir, "build.zig.zon" });
    defer self.gpa.free(zon_path);

    const source = File.readFileSentinel(self.gpa, zon_path) catch return;
    defer self.gpa.free(source);

    var zon = try ZonFile.parse(self.gpa, source);
    errdefer zon.deinit(self.gpa);

    for (zon.path_dependencies.items) |rel| {
        const resolved = try std.fs.path.resolve(self.gpa, &.{ self.build_graph_dir, rel });
        defer self.gpa.free(resolved);
        const canonical = self.canonicalize(resolved) catch continue;
        errdefer self.gpa.free(canonical);
        try self.excluded_dirs.append(self.gpa, canonical);
    }

    self.zon.deinit(self.gpa);
    self.zon = zon;
}

/// Scans one `build.zig` (or a file it locally `@import`s) into `graph`,
/// then recurses into every local-file `@import` it found — see
/// `loadBuildGraph`. `visited` guards against re-scanning the same file
/// twice (an import cycle, or the same helper imported from two places).
fn scanBuildFile(
    self: *Project,
    graph: *BuildGraph,
    visited: *std.StringHashMapUnmanaged(void),
    helper_cache: *HelperFileCache,
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

    const dir = std.fs.path.dirname(canonical) orelse ".";
    var resolve_ctx: HelperResolveCtx = .{ .project = self, .cache = helper_cache, .dir = dir };
    const resolver: BuildGraph.HelperResolver = .{
        .context = &resolve_ctx,
        .resolveFn = HelperResolveCtx.resolve,
        .paramRequirementsFn = HelperResolveCtx.paramRequirements,
    };

    try BuildGraph.parseInto(self.gpa, graph, source, &file_imports, resolver);

    for (file_imports.items) |rel_path| {
        const target_path = std.fs.path.resolve(self.gpa, &.{ dir, rel_path }) catch continue;
        defer self.gpa.free(target_path);
        const target_canonical = self.canonicalize(target_path) catch continue;
        defer self.gpa.free(target_canonical);

        try self.scanBuildFile(graph, visited, helper_cache, target_canonical);
    }
}

/// Caches parsed `Ast`s (keyed by canonical path) of files loaded on demand
/// to resolve a cross-file helper call — see `HelperResolveCtx`. Kept
/// separate from `Project.files`/`File` (which owns a ZLint `Semantic`,
/// overkill for what's just a syntactic AST lookup) and from `visited`
/// (which only tracks the local-`@import` chain `build.zig` itself walks,
/// not files reached solely through a cross-file helper call).
const HelperFileCache = struct {
    const Entry = struct { source: [:0]u8, tree: std.zig.Ast };

    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const empty: HelperFileCache = .{};

    fn deinit(self: *HelperFileCache, gpa: Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.tree.deinit(gpa);
            gpa.free(entry.value_ptr.source);
            gpa.free(entry.key_ptr.*);
        }
        self.entries.deinit(gpa);
    }

    /// Returns the cached (or freshly parsed and cached) `Ast` for
    /// `canonical_path`, or `null` if it can't be read or fails to parse —
    /// best-effort, matching every other lookup this feeds into.
    fn getOrLoad(self: *HelperFileCache, gpa: Allocator, canonical_path: []const u8) !?*const std.zig.Ast {
        if (self.entries.getPtr(canonical_path)) |entry| return &entry.tree;

        const source = File.readFileSentinel(gpa, canonical_path) catch return null;
        errdefer gpa.free(source);
        var tree = std.zig.Ast.parse(gpa, source, .zig) catch return null;
        errdefer tree.deinit(gpa);

        const key = try gpa.dupe(u8, canonical_path);
        errdefer gpa.free(key);
        const gop = try self.entries.getOrPut(gpa, key);
        gop.key_ptr.* = key;
        gop.value_ptr.* = .{ .source = source, .tree = tree };
        return &gop.value_ptr.tree;
    }
};

/// Implements `BuildGraph.HelperResolver` for a `build.zig`-family file
/// currently being scanned: resolves a `<alias>.<fn>(...)` call's callee to
/// whichever file `alias`'s local `@import` specifier points to (relative
/// to `dir`, this file's own directory), loads it via `cache`, and looks up
/// `fn_name`'s `root_source_file` return value there.
const HelperResolveCtx = struct {
    project: *Project,
    cache: *HelperFileCache,
    dir: []const u8,

    fn resolve(context: *anyopaque, gpa: Allocator, rel_import_path: []const u8, fn_name: []const u8) !?[]u8 {
        const self: *HelperResolveCtx = @ptrCast(@alignCast(context));

        const target_path = std.fs.path.resolve(gpa, &.{ self.dir, rel_import_path }) catch return null;
        defer gpa.free(target_path);
        const target_canonical = self.project.canonicalize(target_path) catch return null;
        defer gpa.free(target_canonical);

        const tree = (try self.cache.getOrLoad(gpa, target_canonical)) orelse return null;

        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        var struct_buf: [2]std.zig.Ast.Node.Index = undefined;
        const tok = BuildGraph.rootSourceFileOfHelperFn(tree, fn_name, &call_buf, &struct_buf) orelse return null;
        return BuildGraph.parseStringLiteral(gpa, tree, tok) catch null;
    }

    fn paramRequirements(context: *anyopaque, gpa: Allocator, rel_import_path: []const u8, fn_name: []const u8) !?[]BuildGraph.ParamRequirement {
        const self: *HelperResolveCtx = @ptrCast(@alignCast(context));

        const target_path = std.fs.path.resolve(gpa, &.{ self.dir, rel_import_path }) catch return null;
        defer gpa.free(target_path);
        const target_canonical = self.project.canonicalize(target_path) catch return null;
        defer gpa.free(target_canonical);

        const tree = (try self.cache.getOrLoad(gpa, target_canonical)) orelse return null;

        var out: std.ArrayListUnmanaged(BuildGraph.ParamRequirement) = .empty;
        errdefer {
            for (out.items) |req| {
                gpa.free(req.import_name);
                gpa.free(req.param_field);
            }
            out.deinit(gpa);
        }
        try BuildGraph.paramFieldRequirements(gpa, tree, fn_name, &out);
        return try out.toOwnedSlice(gpa);
    }
};

pub fn file(self: *const Project, id: FileId) *const File {
    return &self.files.items[id.index()];
}

/// Resolves a project-wide `SymbolId` to a copy of the ZLint symbol it
/// identifies. By value: `Symbol.Table.get` hands out a pointer to a
/// temporary copy (its table is a `MultiArrayList`), only valid for the
/// statement that made it.
pub fn symbol(self: *const Project, id: SymbolId) Semantic.Symbol {
    return self.file(id.file).semantic.symbols.symbols.get(id.local.into(usize));
}

/// True iff some configured root transitively imports `path`, or it's one
/// of the build script files `loadBuildGraph` scanned. Only meaningful for
/// canonical paths (e.g. from `discoverZigFiles`). A test-only file is
/// loaded too (Phase 38), so ask `isTestOnly` first when the two need
/// telling apart.
pub fn isReachable(self: *const Project, canonical_path: []const u8) bool {
    return self.by_path.contains(canonical_path) or self.build_files.contains(canonical_path);
}

/// True iff `canonical_path` is reached only through test code (see the
/// module doc) — never analyzed, but not an orphan either.
pub fn isTestOnly(self: *const Project, canonical_path: []const u8) bool {
    return self.test_only_files.contains(canonical_path);
}

/// Adds `path` as a project root: loads it, parses it, and recursively
/// follows its `@import("*.zig")` chain. Returns the root's `FileId`.
///
/// `@import`s inside `test` blocks are deferred, not followed — call
/// `resolveTestImports` once every root is added to classify their
/// targets as test-only files.
pub fn addRoot(self: *Project, path: []const u8) !FileId {
    const id = try self.loadRecursive(path);
    try self.roots.append(self.gpa, id);
    return id;
}

/// Records `path` (a `b.addTest` root module) as a test-only file unless
/// an analysis root already reaches it, then classifies its whole import
/// closure the same way. Loads nothing into `files`.
pub fn addTestRoot(self: *Project, path: []const u8) !void {
    const canonical = try self.canonicalize(path);
    defer self.gpa.free(canonical);
    try self.markTestOnlyClosure(canonical);
}

/// Phase 38: loads every file `resolveTestImports` classified as test-only,
/// tagging each `File.test_only`. They were previously parsed only far
/// enough to read their imports, which left everything they reference
/// looking unreferenced — a whole `staticd/src/tests/` directory's worth of
/// production code reported dead because the only callers sat in files the
/// analysis had deliberately thrown away. Loading them costs nothing in
/// strictness: nothing in a test-only file becomes a production root, and
/// its own declarations are not findings (see `Roots` and `Report`).
///
/// Must run after `resolveTestImports`, since `markTestOnlyClosure` stops
/// at files already in `by_path` and this puts them there.
pub fn loadTestOnlyFiles(self: *Project) !void {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }

    var it = self.test_only_files.keyIterator();
    while (it.next()) |key| try paths.append(self.gpa, try self.gpa.dupe(u8, key.*));

    for (paths.items) |path| {
        _ = self.loadRecursive(path) catch continue;
    }

    // `loadRecursive` pulls in a test-only file's own imports too, so tag by
    // membership afterwards rather than tagging the entry points only.
    for (self.files.items) |*f| {
        if (self.test_only_files.contains(f.path)) f.test_only = true;
    }
}

/// Classifies the target of every `test`-block `@import` deferred by
/// `addRoot`, and its import closure, as test-only. Idempotent; call once
/// every analysis root has been added.
pub fn resolveTestImports(self: *Project) !void {
    while (self.pending_test_imports.items.len > 0) {
        const path = self.pending_test_imports.pop().?;
        defer self.gpa.free(path);
        const canonical = self.canonicalize(path) catch continue;
        defer self.gpa.free(canonical);
        try self.markTestOnlyClosure(canonical);
    }
}

/// Marks `canonical` and everything it transitively `@import`s as
/// test-only, stopping at files an analysis root reaches (`by_path`) and
/// at files already marked. Each test-only file is parsed just far enough
/// to read its imports and then dropped.
fn markTestOnlyClosure(self: *Project, canonical: []const u8) !void {
    var stack: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stack.items) |p| self.gpa.free(p);
        stack.deinit(self.gpa);
    }
    try stack.append(self.gpa, try self.gpa.dupe(u8, canonical));

    while (stack.items.len > 0) {
        const current = stack.pop().?;
        defer self.gpa.free(current);

        if (self.by_path.contains(current) or self.test_only_files.contains(current)) continue;

        var imports: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (imports.items) |p| self.gpa.free(p);
            imports.deinit(self.gpa);
        }
        self.scanImports(current, &imports) catch continue;

        const key = try self.gpa.dupe(u8, current);
        errdefer self.gpa.free(key);
        try self.test_only_files.put(self.gpa, key, {});

        for (imports.items) |target| {
            const target_canonical = self.canonicalize(target) catch continue;
            errdefer self.gpa.free(target_canonical);
            try stack.append(self.gpa, target_canonical);
        }
    }
}

/// Appends to `out` the resolved (not yet canonical) path of every `.zig`
/// file `canonical` imports — relative-file imports and build-graph named
/// modules alike, from `test` blocks or not — without keeping the parsed
/// file around.
fn scanImports(self: *Project, canonical: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    const source = try File.readFileSentinel(self.gpa, canonical);
    defer self.gpa.free(source);

    var builder = Semantic.Builder.init(self.gpa);
    defer builder.deinit();
    var result = try builder.build(source);
    defer result.deinit();

    const dir = std.fs.path.dirname(canonical) orelse ".";
    for (result.value.modules.imports.items) |entry| {
        if (self.build_graph) |bg| {
            if (bg.resolve(entry.specifier)) |rel_paths| {
                for (rel_paths) |rel_path| {
                    const target = std.fs.path.resolve(self.gpa, &.{ self.build_graph_dir, rel_path }) catch continue;
                    try out.append(self.gpa, target);
                }
                continue;
            }
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.specifier, ".zig")) continue;
        const target = std.fs.path.resolve(self.gpa, &.{ dir, entry.specifier }) catch continue;
        try out.append(self.gpa, target);
    }
}

/// Whether `node` (an `@import(...)` call) sits inside a `test { ... }`
/// block of `semantic`'s file.
fn isInTestBlock(semantic: *const Semantic, node: Semantic.Ast.Node.Index) bool {
    const ast = &semantic.parse.ast;
    var cur = semantic.node_links.getParent(node);
    while (cur) |c| : (cur = semantic.node_links.getParent(c)) {
        if (ast.nodeTag(c) == .test_decl) return true;
    }
    return false;
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
        // Test code doesn't count as use: an `@import` inside a `test`
        // block is deferred to `resolveTestImports`, which classifies the
        // target test-only unless some analysis root reaches it for real.
        if (isInTestBlock(&self.files.items[id.index()].semantic, entry.node)) {
            const test_target: ?[]u8 = blk: {
                if (self.build_graph) |bg| {
                    if (bg.resolve(entry.specifier)) |rel_paths| {
                        for (rel_paths) |rel_path| {
                            const target = std.fs.path.resolve(self.gpa, &.{ self.build_graph_dir, rel_path }) catch continue;
                            try self.pending_test_imports.append(self.gpa, target);
                        }
                        break :blk null;
                    }
                }
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.specifier, ".zig")) break :blk null;
                break :blk std.fs.path.resolve(self.gpa, &.{ dir, entry.specifier }) catch null;
            };
            if (test_target) |target| try self.pending_test_imports.append(self.gpa, target);
            continue;
        }

        switch (entry.kind) {
            .module => {
                if (try self.resolveViaBuildGraph(id, entry)) continue;
                const reason: ImportGraph.UnresolvedImport.Reason = if (self.isExternalModule(entry.specifier)) .external else .unknown_module;
                try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node, reason);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.specifier, ".zig")) {
                    try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node, .not_a_zig_file);
                    continue;
                }

                // A build-registered module name always wins over a
                // same-named sibling file — matches real @import
                // semantics, where the compilation's module table is
                // consulted before any filesystem-relative lookup.
                if (try self.resolveViaBuildGraph(id, entry)) continue;

                const target_path = std.fs.path.resolve(self.gpa, &.{ dir, entry.specifier }) catch {
                    try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node, .load_failed);
                    continue;
                };
                defer self.gpa.free(target_path);

                const target_id = self.loadRecursive(target_path) catch {
                    try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node, .load_failed);
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
        try self.import_graph.addUnresolved(self.gpa, id, entry.specifier, entry.kind, entry.node, .load_failed);
    }
    return true;
}

/// Whether `canonical_path` lies under one of `excluded_dirs`.
fn isExcluded(self: *const Project, canonical_path: []const u8) bool {
    for (self.excluded_dirs.items) |dir| {
        if (canonical_path.len > dir.len and
            std.mem.startsWith(u8, canonical_path, dir) and
            canonical_path[dir.len] == std.fs.path.sep) return true;
    }
    return false;
}

fn canonicalize(self: *Project, path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(self.gpa, path);
}

/// Recursively finds every `*.zig` file under `dir` for orphan-file
/// detection: any discovered path that isn't a key of `by_path` after all
/// roots have been loaded was never reached by `@import` from a configured
/// root. Skips any dot-directory (`.git`, `.zig-cache`, ...), `zig-cache`,
/// `zig-out`, `vendor`, and every `build.zig.zon` path dependency
/// (`excluded_dirs`) — all of those are somebody else's files.
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

    const skip_dirs = [_][]const u8{ "zig-cache", "zig-out", "vendor" };

    walk: while (try walker.next()) |entry| {
        var it = std.mem.tokenizeScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |component| {
            if (component.len > 1 and component[0] == '.') continue :walk;
            for (skip_dirs) |skip| {
                if (std.mem.eql(u8, component, skip)) continue :walk;
            }
        }

        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full = try std.fs.path.join(self.gpa, &.{ dir, entry.path });
        defer self.gpa.free(full);
        const canonical = try self.canonicalize(full);
        errdefer self.gpa.free(canonical);
        if (self.isExcluded(canonical)) {
            self.gpa.free(canonical);
            continue;
        }
        try out.append(self.gpa, canonical);
    }

    return out;
}
