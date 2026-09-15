//! Best-effort extraction of a `build.zig`'s local module graph: which
//! `@import("name")` module specifiers resolve to a file on disk, per the
//! `const x = b.createModule(.{ .root_source_file = b.path("...") });`
//! + `<module>.addImport("name", x);` shape used to wire modules together.
//!
//! This is a syntactic scan over `build.zig`'s AST, not a real evaluation
//! of the build script (that would require running it). Modules that come
//! from `b.dependency(...).module(...)` aren't backed by a local file and
//! are left unresolved, same as before this phase existed. A thin local
//! wrapper around `b.path(...)` (`.root_source_file = srcPath(b, "...")`
//! where `srcPath` just returns `b.path(sub_path)`, maybe with a side
//! effect) is inlined through; anything with a more complex body is left
//! unresolved.
//!
//! An import name can resolve to more than one candidate path: when
//! `addImport("name", ...)` is called more than once for the same name
//! (e.g. once per branch of a `target.os.tag` switch/if, each binding a
//! different `createModule`), the scan can't tell which branch actually
//! runs without evaluating the build script. It keeps every candidate and
//! treats all of them as reachable, rather than guessing based on AST
//! order — that avoids false orphan/dead reports for whichever branch
//! it would otherwise have discarded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const BuildGraph = @This();

/// import name -> candidate root source file paths, relative to the
/// `build.zig`'s directory. Usually one path; more than one when the
/// same import name is bound via `addImport` in more than one place
/// (e.g. an OS-conditional module). Owned (keys and every path).
modules: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,

/// Root source file paths (relative to the `build.zig`'s directory) of
/// every `b.addTest(.{ .root_module = ... })` (or older `.root_source_file
/// = ...`) call found — a standalone per-file test binary, compiled and
/// run on its own rather than `@import`ed from anywhere. `Project` loads
/// each of these as if it were a `--root`, so its file (and the files it
/// transitively imports) stop being orphans and its `test { ... }` blocks
/// seed `.test` roots the same way an inline test block in an already-
/// loaded file does. Owned.
test_roots: std.ArrayListUnmanaged([]const u8) = .empty,

/// Root source file paths (relative to the `build.zig`'s directory) of
/// every `b.addExecutable(.{ ... })` / `b.addLibrary(.{ ... })` call
/// found — same `.root_module`/`.root_source_file` extraction as
/// `test_roots`, but for a project's compiled artifacts rather than its
/// standalone test binaries. `Project` loads each of these as if it were
/// a `--root` too, so a `build.zig`-driven run with no explicit `--root`
/// still reaches an executable's `main` (or a library's exports) instead
/// of reporting the whole thing orphaned. Owned.
exe_roots: std.ArrayListUnmanaged([]const u8) = .empty,

/// Whether a `b.addExecutable(...)` call was found anywhere in the scan,
/// regardless of whether its root module's path could be resolved — used
/// (together with `has_library`) to infer executable vs. library
/// reachability semantics when no policy is given explicitly.
has_executable: bool = false,

/// Whether a `b.addLibrary(...)` call was found anywhere in the scan,
/// regardless of whether its root module's path could be resolved. A
/// `build.zig` that defines a library and no executable is the signal
/// used to default to library mode (every `pub` symbol is reachable API)
/// instead of executable mode.
has_library: bool = false,

/// Every `addImport("name", ...)` / `.imports = &.{ .{ .name = "name", ...
/// } }` name whose module value is *not* one of this project's
/// `createModule`/`b.path` bindings — a `b.dependency(...).module(...)`,
/// or anything else the scan can't trace to a local file. Such a name is
/// an external package as far as the project is concerned: an
/// `@import("name")` of it is neither dead code nor a configuration gap.
/// Owned.
external_names: std.StringHashMapUnmanaged(void) = .empty,

pub const empty: BuildGraph = .{};

/// Resolves a cross-file helper call site's callee (`<local-file-alias>.
/// <fn>(...)`) to the `root_source_file` path its body returns —
/// implemented by `Project`, which owns the file loading/caching and
/// canonical-path resolution `parseInto` itself has no access to.
/// `rel_import_path` is the local-file `@import` specifier the callee's
/// namespace alias was bound from (e.g. `"build/vendor.zig"`), resolved by
/// the implementer relative to the *calling* file's directory; `fn_name` is
/// the callee. Returns `null` (not an error) for a helper that can't be
/// found or whose body doesn't match the recognized shape — same
/// best-effort semantics as every other lookup in this file.
pub const HelperResolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (context: *anyopaque, gpa: Allocator, rel_import_path: []const u8, fn_name: []const u8) anyerror!?[]u8,
    /// Resolves an `Options`-struct-forwarding call site — see
    /// `ParamRequirement` and `paramFieldRequirements`.
    paramRequirementsFn: *const fn (context: *anyopaque, gpa: Allocator, rel_import_path: []const u8, fn_name: []const u8) anyerror!?[]ParamRequirement,

    fn resolve(self: HelperResolver, gpa: Allocator, rel_import_path: []const u8, fn_name: []const u8) !?[]u8 {
        return self.resolveFn(self.context, gpa, rel_import_path, fn_name);
    }

    fn paramRequirements(self: HelperResolver, gpa: Allocator, rel_import_path: []const u8, fn_name: []const u8) !?[]ParamRequirement {
        return self.paramRequirementsFn(self.context, gpa, rel_import_path, fn_name);
    }
};

/// One `addImport("<import_name>", opts.<param_field>)` (or an `addImport`
/// fed by a `b.createModule(.{ .root_source_file = b.path(opts.<param_field>)
/// })` bound to a local var) found inside a `wire`-shaped function's body —
/// see `paramFieldRequirements`. Both fields are owned, caller-freed copies.
pub const ParamRequirement = struct {
    import_name: []const u8,
    param_field: []const u8,

    fn deinit(self: ParamRequirement, gpa: Allocator) void {
        gpa.free(self.import_name);
        gpa.free(self.param_field);
    }
};

pub fn freeParamRequirements(gpa: Allocator, requirements: []ParamRequirement) void {
    for (requirements) |req| req.deinit(gpa);
    gpa.free(requirements);
}

pub fn deinit(self: *BuildGraph, gpa: Allocator) void {
    var it = self.modules.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        for (entry.value_ptr.items) |path| gpa.free(path);
        entry.value_ptr.deinit(gpa);
    }
    self.modules.deinit(gpa);
    for (self.test_roots.items) |path| gpa.free(path);
    self.test_roots.deinit(gpa);
    for (self.exe_roots.items) |path| gpa.free(path);
    self.exe_roots.deinit(gpa);
    var ext_it = self.external_names.keyIterator();
    while (ext_it.next()) |k| gpa.free(k.*);
    self.external_names.deinit(gpa);
    self.* = undefined;
}

/// Whether `name` was bound by an `addImport` whose module the scan could
/// not trace to a local file — see `external_names`.
pub fn isExternal(self: *const BuildGraph, name: []const u8) bool {
    return self.external_names.contains(name);
}

/// Records `import_name` (owned; freed here if already present) as an
/// external module name.
fn addExternalName(gpa: Allocator, result: *BuildGraph, import_name: []u8) !void {
    const gop = try result.external_names.getOrPut(gpa, import_name);
    if (gop.found_existing) {
        gpa.free(import_name);
    } else {
        gop.key_ptr.* = import_name;
    }
}

/// Returns every candidate root source file path `name` resolves to, or
/// `null` if `name` isn't a locally-created module.
pub fn resolve(self: *const BuildGraph, name: []const u8) ?[]const []const u8 {
    const paths = self.modules.getPtr(name) orelse return null;
    return paths.items;
}

/// Scans `source` and merges the local module bindings it defines into
/// `result`, which may already hold bindings merged in from another file
/// in the same build script's local-`@import` chain (see
/// `Project.loadBuildGraph`, which drives the recursion across files).
/// Every top-level `const x = @import("relative/file.zig");` local-file
/// import is appended (as an owned, caller-freed copy) to `file_imports`
/// so the caller can resolve it relative to *this* file's directory, load
/// it, and recurse — while every `b.path(...)` string collected here (and
/// by the recursive calls) stays a bare relative path, resolved by the
/// caller against the original build root regardless of which file it
/// was found in, matching how `b.path` actually behaves at runtime.
/// `source` need not be error-free; a file with parse errors just
/// contributes nothing. `resolver`, if given, is consulted for a call-site
/// shape neither `rootSourceFileOfCreateModule` nor `bindStructReturnFields`
/// covers: `<local-file-alias>.<fn>(...)`, a helper declared in a
/// different, locally-`@import`ed file (see `HelperResolver`).
pub fn parseInto(
    gpa: Allocator,
    result: *BuildGraph,
    source: [:0]const u8,
    file_imports: *std.ArrayListUnmanaged([]u8),
    resolver: ?HelperResolver,
) !void {
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    // local variable name -> root_source_file path (borrowed from `tree`).
    var bindings: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer bindings.deinit(gpa);

    // local variable name -> string-literal token of the relative path a
    // `const <name> = @import("relative/file.zig");` binds, so a later
    // `<name>.<fn>(...)` call site can be resolved cross-file via
    // `resolver`. Borrowed from `tree`.
    var import_aliases: std.StringHashMapUnmanaged(Ast.TokenIndex) = .empty;
    defer import_aliases.deinit(gpa);

    // "<var>.<field>" -> root_source_file path, for `mods.foo` where `mods`
    // is bound to the result of a local helper that returns `.{ .foo = foo,
    // ... }` (see `bindStructReturnFields`). Unlike `bindings`, both key and
    // value are owned here.
    var field_bindings: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var fit = field_bindings.iterator();
        while (fit.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        field_bindings.deinit(gpa);
    }

    var call_buf: [1]Ast.Node.Index = undefined;
    var struct_buf: [2]Ast.Node.Index = undefined;

    // Every binding first, then everything that reads one. A `build.zig`
    // that stratifies into helpers declares `wireExe` — which says
    // `addImport("mph", shared.mph)` — above the `wire()` that binds
    // `const shared = wireShared(...)`, so a single pass meets `shared.mph`
    // before it knows what `shared` is and drops the module. Nothing in the
    // binding pass records a root, so hoisting it can only add resolutions.
    try collectBindings(gpa, &tree, &bindings, &import_aliases, &field_bindings, file_imports, resolver);

    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);

        if (tree.fullVarDecl(node) != null) {
            try bindVarDecl(gpa, &tree, node, &bindings, &import_aliases, &field_bindings, null, resolver);
            continue;
        }

        if (tree.fullStructInit(&struct_buf, node)) |struct_init| {
            for (struct_init.ast.fields) |field_value| {
                const name_tok = tree.firstToken(field_value) - 2;
                if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "imports")) continue;
                try scanImportsField(gpa, &tree, &bindings, &field_bindings, result, field_value);
            }
            continue;
        }

        if (tree.fullFor(node)) |for_full| {
            try scanRootTableLoop(gpa, &tree, result, for_full);
            try scanTableForwardedModules(gpa, &tree, result, for_full, resolver, &import_aliases);
            continue;
        }

        const call = tree.fullCall(&call_buf, node) orelse continue;

        // A bare-identifier callee is a local helper, never `b.<method>`, so
        // it can only declare a root through the shape
        // `rootParamOfLocalHelper` recognizes. Checking it here keeps the
        // dispatch below reading as a flat list of `b.<method>` names.
        if (tree.nodeTag(call.ast.fn_expr) == .identifier) {
            const helper_name = tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr));
            if (rootParamOfLocalHelper(&tree, helper_name)) |found| {
                if (found.index < call.ast.params.len) {
                    const arg = call.ast.params[found.index];
                    if (tree.nodeTag(arg) == .string_literal) {
                        const path = parseStringLiteral(gpa, &tree, tree.nodeMainToken(arg)) catch continue;
                        errdefer gpa.free(path);
                        switch (found.kind) {
                            .test_root => try result.test_roots.append(gpa, path),
                            .exe_root => try result.exe_roots.append(gpa, path),
                        }
                    }
                }
            }
            continue;
        }

        const field = fieldAccessName(&tree, call.ast.fn_expr) orelse continue;

        if (std.mem.eql(u8, field, "addTest")) {
            if (call.ast.params.len >= 1) {
                if (try testRootFromOptions(gpa, &tree, &bindings, &field_bindings, call.ast.params[0], &struct_buf, &call_buf)) |path| {
                    errdefer gpa.free(path);
                    try result.test_roots.append(gpa, path);
                }
            }
            continue;
        }

        if (std.mem.eql(u8, field, "addExecutable") or std.mem.eql(u8, field, "addLibrary")) {
            if (std.mem.eql(u8, field, "addExecutable")) {
                result.has_executable = true;
            } else {
                result.has_library = true;
            }
            if (call.ast.params.len >= 1) {
                if (try testRootFromOptions(gpa, &tree, &bindings, &field_bindings, call.ast.params[0], &struct_buf, &call_buf)) |path| {
                    errdefer gpa.free(path);
                    try result.exe_roots.append(gpa, path);
                }
            }
            continue;
        }

        if (std.mem.eql(u8, field, "addModule")) {
            // `b.addModule("name", ...)` exports a source module for other
            // packages to `@import` — the package-manager convention for a
            // library with no compiled artifact of its own. Its `pub`
            // surface is real API, so it counts as a library for the
            // executable-vs-library policy inference.
            result.has_library = true;
            if (nameAndRootSourceFileOfAddModule(&tree, call, &struct_buf)) |found| {
                const import_name = parseStringLiteral(gpa, &tree, found.name) catch continue;
                errdefer gpa.free(import_name);
                const path = parseStringLiteral(gpa, &tree, found.path) catch {
                    gpa.free(import_name);
                    continue;
                };
                defer gpa.free(path);
                try addModulePath(gpa, result, import_name, path);
            }
            continue;
        }

        if (std.mem.eql(u8, field, "addAnonymousImport")) {
            if (call.ast.params.len >= 2 and tree.nodeTag(call.ast.params[0]) == .string_literal) {
                if (rootSourceFileFromOptions(&tree, call.ast.params[1], &struct_buf)) |path_tok| {
                    const import_name = parseStringLiteral(gpa, &tree, tree.nodeMainToken(call.ast.params[0])) catch continue;
                    errdefer gpa.free(import_name);
                    const path = parseStringLiteral(gpa, &tree, path_tok) catch {
                        gpa.free(import_name);
                        continue;
                    };
                    defer gpa.free(path);
                    try addModulePath(gpa, result, import_name, path);
                }
            }
            continue;
        }

        if (resolver) |r| {
            if (crossFileHelperCall(&tree, call)) |helper_call| {
                if (import_aliases.get(helper_call.alias)) |alias_tok| {
                    try resolveParamForwardingCall(gpa, &tree, r, alias_tok, helper_call.fn_name, &bindings, &field_bindings, call, result, &struct_buf);
                }
            }
        }

        if (!std.mem.eql(u8, field, "addImport")) continue;
        if (call.ast.params.len < 2) continue;

        const name_node = call.ast.params[0];
        if (tree.nodeTag(name_node) != .string_literal) continue;
        const import_name = parseStringLiteral(gpa, &tree, tree.nodeMainToken(name_node)) catch continue;
        errdefer gpa.free(import_name);

        const value_node = call.ast.params[1];
        const rel_path = pathForBinding(&tree, &bindings, &field_bindings, value_node) orelse {
            try addExternalName(gpa, result, import_name);
            continue;
        };

        try addModulePath(gpa, result, import_name, rel_path);
    }

    // `bindings`' values are owned by `result` iff still referenced; free
    // whichever weren't picked up by an `addImport`.
    var bit = bindings.iterator();
    while (bit.next()) |entry| gpa.free(entry.value_ptr.*);
}

/// If `node` is `@import("relative/file.zig")` — a local-file import
/// specifier (ends in `.zig`, as opposed to a package name like `"std"`
/// or a named module like `"storage"`) — returns the token index of the
/// string literal.
fn localFileImportPath(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;

    var buf: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, node) orelse return null;
    if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) return null;

    const tok = tree.nodeMainToken(params[0]);
    if (!std.mem.endsWith(u8, tree.tokenSlice(tok), ".zig\"")) return null;
    return tok;
}

/// The binding half of `parseInto`'s scan, hoisted into its own pass over
/// every node: local variables bound to a module's root source file, to a
/// local-file `@import`, or to a struct of modules a helper returned. See
/// `parseInto` for why this can't share the pass that reads them.
fn collectBindings(
    gpa: Allocator,
    tree: *const Ast,
    bindings: *std.StringHashMapUnmanaged([]const u8),
    import_aliases: *std.StringHashMapUnmanaged(Ast.TokenIndex),
    field_bindings: *std.StringHashMapUnmanaged([]const u8),
    file_imports: *std.ArrayListUnmanaged([]u8),
    resolver: ?HelperResolver,
) !void {
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        try bindVarDecl(gpa, tree, node, bindings, import_aliases, field_bindings, file_imports, resolver);
    }
}

/// Binds whatever `node` declares, if it declares anything this cares about.
/// `file_imports` is null on the second pass: the `@import` list is built
/// once, by `collectBindings`, while the bindings themselves are rebuilt in
/// source order so a name shadowed by a sibling block (`{ const m = ...; }`
/// repeated per test) still resolves to its own block's module at the point
/// that block's `addTest` is read.
fn bindVarDecl(
    gpa: Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
    bindings: *std.StringHashMapUnmanaged([]const u8),
    import_aliases: *std.StringHashMapUnmanaged(Ast.TokenIndex),
    field_bindings: *std.StringHashMapUnmanaged([]const u8),
    file_imports: ?*std.ArrayListUnmanaged([]u8),
    resolver: ?HelperResolver,
) !void {
    var call_buf: [1]Ast.Node.Index = undefined;
    var struct_buf: [2]Ast.Node.Index = undefined;

    const var_decl = tree.fullVarDecl(node) orelse return;
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    const var_name = tree.tokenSlice(var_decl.ast.mut_token + 1);

    if (rootSourceFileOfCreateModule(tree, init_node, &call_buf, &struct_buf)) |rel_path| {
        const path = parseStringLiteral(gpa, tree, rel_path) catch return;
        errdefer gpa.free(path);
        return putBinding(gpa, bindings, var_name, path);
    }

    if (tree.fullCall(&call_buf, init_node)) |call| {
        if (nameAndRootSourceFileOfAddModule(tree, call, &struct_buf)) |found| {
            const path = parseStringLiteral(gpa, tree, found.path) catch return;
            errdefer gpa.free(path);
            return putBinding(gpa, bindings, var_name, path);
        }

        if (try resolveCrossFileHelper(gpa, tree, resolver, import_aliases, call)) |path| {
            errdefer gpa.free(path);
            return putBinding(gpa, bindings, var_name, path);
        }

        try bindStructReturnFields(gpa, tree, bindings, field_bindings, var_name, call, &struct_buf);
    }

    const imports = file_imports orelse return;
    if (localFileImportPath(tree, init_node)) |path_tok| {
        const path = parseStringLiteral(gpa, tree, path_tok) catch return;
        errdefer gpa.free(path);
        try imports.append(gpa, path);
        try import_aliases.put(gpa, var_name, path_tok);
    }
}

/// If `node` is `<ident>.createModule(.{ ..., .root_source_file =
/// b.path("...") , ... })`, returns the token index of that inner string
/// literal. Also recognizes a single-argument call to a locally-defined
/// pass-through helper (`.root_source_file = srcPath(b, "...")` where
/// `srcPath`'s body is exactly `return b.path(sub_path);`) and inlines
/// through it to the same string literal at the call site.
fn rootSourceFileOfCreateModule(
    tree: *const Ast,
    node: Ast.Node.Index,
    call_buf: *[1]Ast.Node.Index,
    struct_buf: *[2]Ast.Node.Index,
) ?Ast.TokenIndex {
    const call = tree.fullCall(call_buf, node) orelse return null;
    const field = fieldAccessName(tree, call.ast.fn_expr) orelse return null;
    if (!std.mem.eql(u8, field, "createModule")) return null;
    if (call.ast.params.len < 1) return null;

    return rootSourceFileFromOptions(tree, call.ast.params[0], struct_buf);
}

/// If `node` is `<ident>.addModule("name", .{ ..., .root_source_file =
/// b.path("...") , ... })` — the single-call shape that both names and
/// creates a module, unlike `createModule` which needs a separate
/// `addImport`/`.imports` to be reachable by name — the module name and
/// the token index of the inner root-source-file string literal (same
/// extraction, and same pass-through-helper handling, as
/// `rootSourceFileOfCreateModule`).
fn nameAndRootSourceFileOfAddModule(
    tree: *const Ast,
    call: Ast.full.Call,
    struct_buf: *[2]Ast.Node.Index,
) ?struct { name: Ast.TokenIndex, path: Ast.TokenIndex } {
    const field = fieldAccessName(tree, call.ast.fn_expr) orelse return null;
    if (!std.mem.eql(u8, field, "addModule")) return null;
    if (call.ast.params.len < 2) return null;

    const name_node = call.ast.params[0];
    if (tree.nodeTag(name_node) != .string_literal) return null;

    const path = rootSourceFileFromOptions(tree, call.ast.params[1], struct_buf) orelse return null;
    return .{ .name = tree.nodeMainToken(name_node), .path = path };
}

/// Finds the `.root_source_file = b.path("...")` field (or a pass-through
/// helper call in its place, see `pathThroughHelperCall`; or a
/// `.{ .cwd_relative = ... }` `LazyPath` literal, see `cwdRelativePathToken`)
/// in `options` — a `.{ ... }` struct-literal node — and returns the token
/// index of the string literal it resolves to.
fn rootSourceFileFromOptions(tree: *const Ast, options: Ast.Node.Index, struct_buf: *[2]Ast.Node.Index) ?Ast.TokenIndex {
    const struct_init = tree.fullStructInit(struct_buf, options) orelse return null;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_source_file")) continue;
        if (cwdRelativePathToken(tree, field_value)) |tok| return tok;
        var inner_buf: [1]Ast.Node.Index = undefined;
        const path_call = tree.fullCall(&inner_buf, field_value) orelse return null;
        if (fieldAccessName(tree, path_call.ast.fn_expr)) |path_field| {
            if (!std.mem.eql(u8, path_field, "path")) return null;
            if (path_call.ast.params.len < 1) return null;
            const arg = path_call.ast.params[0];
            if (tree.nodeTag(arg) != .string_literal) return null;
            return tree.nodeMainToken(arg);
        }
        return pathThroughHelperCall(tree, path_call);
    }
    return null;
}

/// If `node` is a `std.Build.LazyPath` struct literal `.{ .cwd_relative =
/// "..." }` (direct absolute/cwd-relative string) or `.{ .cwd_relative =
/// b.pathFromRoot("...") }` (a path built from something rooted a directory
/// or two above `b`'s own root), returns the token index of the inner
/// string literal — `pathFromRoot`'s argument is relative to the build root
/// exactly like `b.path`'s argument is relative to `build.zig`'s directory,
/// so it's resolved by the caller the same way. Uses its own local buffer
/// rather than a caller-supplied one since it's called while iterating an
/// outer struct-literal's fields, which may still be borrowing that buffer.
fn cwdRelativePathToken(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    var inner_struct_buf: [2]Ast.Node.Index = undefined;
    const inner_struct = tree.fullStructInit(&inner_struct_buf, node) orelse return null;
    for (inner_struct.ast.fields) |inner_field| {
        const name_tok = tree.firstToken(inner_field) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "cwd_relative")) continue;
        if (tree.nodeTag(inner_field) == .string_literal) return tree.nodeMainToken(inner_field);

        var call_buf: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buf, inner_field) orelse return null;
        const field = fieldAccessName(tree, call.ast.fn_expr) orelse return null;
        if (!std.mem.eql(u8, field, "pathFromRoot")) return null;
        if (call.ast.params.len < 1) return null;
        const arg = call.ast.params[0];
        if (tree.nodeTag(arg) != .string_literal) return null;
        return tree.nodeMainToken(arg);
    }
    return null;
}

/// If `options` (a `b.addTest(.{ ... })` / `b.addExecutable(.{ ... })` /
/// `b.addLibrary(.{ ... })` call's first argument) is either
/// the older `.{ .root_source_file = b.path("...") }` shape (delegated to
/// `rootSourceFileFromOptions`) or the current `.{ .root_module = <module>
/// }` shape — `<module>` a local variable bound to a `createModule` call
/// found earlier in the same scan, a field access into a struct of modules
/// a local helper returned (`mods.main`, see `pathForBinding`), or an
/// inline `b.createModule(...)` call — returns that module's root source
/// file path, freshly allocated. `null` if neither shape matches, or the
/// path couldn't be resolved.
///
/// The module-valued shapes all go through `pathForBinding`, the same
/// resolution `addImport`'s second argument gets: an app binary declared as
/// `b.addExecutable(.{ .root_module = mods.main })` is exactly as much a
/// root as one declared with the module inline, and missing it costs a
/// whole binary's reachability.
fn testRootFromOptions(
    gpa: Allocator,
    tree: *const Ast,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
    field_bindings: *const std.StringHashMapUnmanaged([]const u8),
    options: Ast.Node.Index,
    struct_buf: *[2]Ast.Node.Index,
    call_buf: *[1]Ast.Node.Index,
) !?[]u8 {
    if (rootSourceFileFromOptions(tree, options, struct_buf)) |tok| {
        return parseStringLiteral(gpa, tree, tok) catch null;
    }

    const struct_init = tree.fullStructInit(struct_buf, options) orelse return null;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_module")) continue;

        if (pathForBinding(tree, bindings, field_bindings, field_value)) |path| {
            return try gpa.dupe(u8, path);
        }

        if (rootSourceFileOfCreateModule(tree, field_value, call_buf, struct_buf)) |tok| {
            return parseStringLiteral(gpa, tree, tok) catch null;
        }
        return null;
    }
    return null;
}

/// If `call` is a single-argument call to a locally-defined function whose
/// body is exactly `return <recv>.path(<param>);` (a thin pass-through
/// wrapper around `b.path(...)`, e.g. one that also validates the path
/// exists first), resolves through it to the string-literal token passed at
/// `call`'s own call site — the same shape a direct `b.path("...")` call
/// would yield. Anything with a more complex body is left unresolved.
fn pathThroughHelperCall(tree: *const Ast, call: Ast.full.Call) ?Ast.TokenIndex {
    if (tree.nodeTag(call.ast.fn_expr) != .identifier) return null;
    const fn_name = tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr));

    const fn_decl = findFnDecl(tree, fn_name) orelse return null;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buf, fn_decl) orelse return null;
    const body = tree.nodeData(fn_decl).node_and_node[1];

    const param_index = passThroughPathParamIndex(tree, proto, body) orelse return null;
    if (param_index >= call.ast.params.len) return null;

    const arg = call.ast.params[param_index];
    if (tree.nodeTag(arg) != .string_literal) return null;
    return tree.nodeMainToken(arg);
}

/// If `body` (a function's block) ends with `return <recv>.path(<param>);`
/// — any statements before it don't matter, e.g. a leading path-validation
/// call — returns the index of `<param>` among `proto`'s parameters.
fn passThroughPathParamIndex(tree: *const Ast, proto: Ast.full.FnProto, body: Ast.Node.Index) ?usize {
    var stmt_buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&stmt_buf, body) orelse return null;
    if (stmts.len == 0) return null;
    const last = stmts[stmts.len - 1];
    if (tree.nodeTag(last) != .@"return") return null;
    const ret_expr = tree.nodeData(last).opt_node.unwrap() orelse return null;

    var call_buf: [1]Ast.Node.Index = undefined;
    const inner_call = tree.fullCall(&call_buf, ret_expr) orelse return null;
    const field = fieldAccessName(tree, inner_call.ast.fn_expr) orelse return null;
    if (!std.mem.eql(u8, field, "path")) return null;
    if (inner_call.ast.params.len != 1) return null;

    const arg = inner_call.ast.params[0];
    if (tree.nodeTag(arg) != .identifier) return null;
    const arg_name = tree.tokenSlice(tree.nodeMainToken(arg));

    return paramIndexNamed(tree, proto, arg_name);
}

/// The index of `proto`'s parameter named `name`, so a call site's argument
/// list can be indexed the same way the body's use of the parameter was.
fn paramIndexNamed(tree: *const Ast, proto: Ast.full.FnProto, name: []const u8) ?usize {
    var it = proto.iterate(tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        const name_tok = param.name_token orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(name_tok), name)) return index;
    }
    return null;
}

/// If `call.ast.fn_expr` is `<alias>.<fn_name>` (a field access on a bare
/// identifier, e.g. `vendor.yamlModule`), returns `alias` and `fn_name` so
/// the caller can check whether `alias` is a known local-file `@import`
/// alias and, if so, try `resolver` against it. `null` for anything else
/// (a builtin/namespace call like `b.createModule(...)`, a nested field
/// chain, a bare-identifier callee — those are handled elsewhere).
fn crossFileHelperCall(tree: *const Ast, call: Ast.full.Call) ?struct { alias: []const u8, fn_name: []const u8 } {
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (tree.nodeTag(data[0]) != .identifier) return null;
    return .{
        .alias = tree.tokenSlice(tree.nodeMainToken(data[0])),
        .fn_name = tree.tokenSlice(data[1]),
    };
}

/// If `call` is `<alias>.<fn>(...)` where `alias` is a known local-file
/// `@import` alias (recorded in `import_aliases`) and `resolver` is given,
/// asks `resolver` to resolve `fn` (as defined in whichever file `alias`'s
/// import specifier points to) to a `root_source_file` path — see
/// `HelperResolver`. Returns `null` (not an error) whenever the shape
/// doesn't match or the resolver can't find anything, matching every other
/// lookup in this file.
fn resolveCrossFileHelper(
    gpa: Allocator,
    tree: *const Ast,
    resolver: ?HelperResolver,
    import_aliases: *const std.StringHashMapUnmanaged(Ast.TokenIndex),
    call: Ast.full.Call,
) !?[]u8 {
    const r = resolver orelse return null;
    const helper_call = crossFileHelperCall(tree, call) orelse return null;
    const alias_tok = import_aliases.get(helper_call.alias) orelse return null;
    const rel_path = parseStringLiteral(gpa, tree, alias_tok) catch return null;
    defer gpa.free(rel_path);
    return r.resolve(gpa, rel_path, helper_call.fn_name) catch null;
}

/// If `call` is `<alias>.<fn>(..., .{ .field = value, ... })` where `alias`
/// is a known local-file `@import` alias (recorded in `import_aliases`) and
/// `resolver` is given, asks `resolver` for `fn`'s `ParamRequirement`s (as
/// defined in whichever file `alias`'s import specifier points to) and, for
/// every requirement whose `param_field` matches a field in this call's
/// struct-literal argument, resolves that field's value to a path (via
/// `pathForBinding`, against bindings already accumulated by this scan) and
/// records it directly in `result` under the requirement's `import_name` —
/// closing the loop `apps/<name>/build.zig: pub fn wire(b, opts: Options)`
/// leaves open (see issues/39): `opts.<field>` isn't a traceable local
/// variable inside `wire`'s own file, but the value it stands for is right
/// here at the call site. Best-effort: does nothing if the resolver can't
/// find a matching `wire`-shaped function or a requirement's field isn't
/// supplied at this call site.
fn resolveParamForwardingCall(
    gpa: Allocator,
    tree: *const Ast,
    resolver: HelperResolver,
    alias_tok: Ast.TokenIndex,
    fn_name: []const u8,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
    field_bindings: *const std.StringHashMapUnmanaged([]const u8),
    call: Ast.full.Call,
    result: *BuildGraph,
    struct_buf: *[2]Ast.Node.Index,
) !void {
    var options_node: ?Ast.Node.Index = null;
    for (call.ast.params) |param| {
        if (tree.fullStructInit(struct_buf, param) != null) {
            options_node = param;
            break;
        }
    }
    const options = options_node orelse return;
    const struct_init = tree.fullStructInit(struct_buf, options) orelse return;

    const rel_path = parseStringLiteral(gpa, tree, alias_tok) catch return;
    defer gpa.free(rel_path);

    const requirements = (resolver.paramRequirements(gpa, rel_path, fn_name) catch return) orelse return;
    defer freeParamRequirements(gpa, requirements);

    for (requirements) |req| {
        for (struct_init.ast.fields) |field_value| {
            const name_tok = tree.firstToken(field_value) - 2;
            if (!std.mem.eql(u8, tree.tokenSlice(name_tok), req.param_field)) continue;
            const path = pathForBinding(tree, bindings, field_bindings, field_value) orelse continue;
            const import_name = try gpa.dupe(u8, req.import_name);
            errdefer gpa.free(import_name);
            try addModulePath(gpa, result, import_name, path);
        }
    }
}

/// Scans `fn_name`'s body in `tree` for `addImport("<name>", opts.<field>)`
/// calls (or an `addImport` fed by a local var bound to `b.createModule(.{
/// .root_source_file = b.path(opts.<field>) })`) where `opts` is one of
/// `fn_name`'s own parameters — the "forwards a caller-supplied module/path
/// through an `Options` struct field" shape (see issues/39) — and appends a
/// `ParamRequirement` for each to `out`. Scoped to the function's body by
/// token position (like the rest of this file, a flat/best-effort scan
/// rather than a real scope-aware walk); `fn_name` not found, or found with
/// no matching parameter, yields no requirements.
pub fn paramFieldRequirements(
    gpa: Allocator,
    tree: *const Ast,
    fn_name: []const u8,
    out: *std.ArrayListUnmanaged(ParamRequirement),
) !void {
    const fn_decl = findFnDecl(tree, fn_name) orelse return;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buf, fn_decl) orelse return;

    var param_names_buf: [8][]const u8 = undefined;
    var param_count: usize = 0;
    var pit = proto.iterate(tree);
    while (pit.next()) |param| {
        const name_tok = param.name_token orelse continue;
        if (param_count >= param_names_buf.len) break;
        param_names_buf[param_count] = tree.tokenSlice(name_tok);
        param_count += 1;
    }
    const param_names = param_names_buf[0..param_count];
    if (param_names.len == 0) return;

    const body = tree.nodeData(fn_decl).node_and_node[1];
    const body_start = tree.firstToken(body);
    const body_end = tree.lastToken(body);

    // local var (inside fn_name's body) -> param field name, for a
    // `b.createModule(.{ .root_source_file = b.path(opts.<field>) })` bound
    // to a var later passed to `addImport`.
    var param_bindings: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer param_bindings.deinit(gpa);

    var call_buf: [1]Ast.Node.Index = undefined;
    var struct_buf: [2]Ast.Node.Index = undefined;

    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        const start_tok = tree.firstToken(node);
        if (start_tok < body_start or start_tok > body_end) continue;

        if (tree.fullVarDecl(node)) |var_decl| {
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            const var_name_tok = var_decl.ast.mut_token + 1;
            const var_name = tree.tokenSlice(var_name_tok);

            if (paramFieldOfCreateModule(tree, init_node, param_names, &call_buf, &struct_buf)) |pfield| {
                try param_bindings.put(gpa, var_name, pfield);
            }
            continue;
        }

        const call = tree.fullCall(&call_buf, node) orelse continue;
        const field = fieldAccessName(tree, call.ast.fn_expr) orelse continue;
        if (!std.mem.eql(u8, field, "addImport")) continue;
        if (call.ast.params.len < 2) continue;

        const name_node = call.ast.params[0];
        if (tree.nodeTag(name_node) != .string_literal) continue;

        const value_node = call.ast.params[1];
        const param_field = paramFieldOfValue(tree, value_node, param_names, &param_bindings) orelse continue;

        const import_name = parseStringLiteral(gpa, tree, tree.nodeMainToken(name_node)) catch continue;
        errdefer gpa.free(import_name);
        const field_dup = try gpa.dupe(u8, param_field);
        errdefer gpa.free(field_dup);
        try out.append(gpa, .{ .import_name = import_name, .param_field = field_dup });
    }
}

/// If `node` is `<recv>.createModule(.{ ..., .root_source_file =
/// b.path(<ident>.<field>) , ... })` where `<ident>` names one of
/// `param_names`, returns `<field>` — the parameterized-path counterpart of
/// `rootSourceFileOfCreateModule`, which only handles a literal path.
fn paramFieldOfCreateModule(
    tree: *const Ast,
    node: Ast.Node.Index,
    param_names: []const []const u8,
    call_buf: *[1]Ast.Node.Index,
    struct_buf: *[2]Ast.Node.Index,
) ?[]const u8 {
    const call = tree.fullCall(call_buf, node) orelse return null;
    const field = fieldAccessName(tree, call.ast.fn_expr) orelse return null;
    if (!std.mem.eql(u8, field, "createModule")) return null;
    if (call.ast.params.len < 1) return null;

    const struct_init = tree.fullStructInit(struct_buf, call.ast.params[0]) orelse return null;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_source_file")) continue;

        var inner_buf: [1]Ast.Node.Index = undefined;
        const path_call = tree.fullCall(&inner_buf, field_value) orelse return null;
        const path_field = fieldAccessName(tree, path_call.ast.fn_expr) orelse return null;
        if (!std.mem.eql(u8, path_field, "path")) return null;
        if (path_call.ast.params.len < 1) return null;

        return paramFieldOfArg(tree, path_call.ast.params[0], param_names);
    }
    return null;
}

/// If `arg` is `<ident>.<field>` where `<ident>` names one of `param_names`,
/// returns `<field>`.
fn paramFieldOfArg(tree: *const Ast, arg: Ast.Node.Index, param_names: []const []const u8) ?[]const u8 {
    if (tree.nodeTag(arg) != .field_access) return null;
    const base_node = tree.nodeData(arg).node_and_token[0];
    if (tree.nodeTag(base_node) != .identifier) return null;
    const base = tree.tokenSlice(tree.nodeMainToken(base_node));

    for (param_names) |p| {
        if (std.mem.eql(u8, base, p)) return fieldAccessName(tree, arg);
    }
    return null;
}

/// Resolves an `addImport` second argument to a parameter field name: either
/// directly `opts.<field>`, or an identifier already bound in
/// `param_bindings` by `paramFieldOfCreateModule`.
fn paramFieldOfValue(
    tree: *const Ast,
    value_node: Ast.Node.Index,
    param_names: []const []const u8,
    param_bindings: *const std.StringHashMapUnmanaged([]const u8),
) ?[]const u8 {
    switch (tree.nodeTag(value_node)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(value_node));
            return param_bindings.get(name);
        },
        .field_access => return paramFieldOfArg(tree, value_node, param_names),
        else => return null,
    }
}

/// If `tree` contains a `fn <fn_name>(...) ... { ... }` declaration whose
/// body's last statement is `return <recv>.createModule(...);` (any
/// statements before it don't matter, e.g. a leading validation call — same
/// relaxation `passThroughPathParamIndex` allows for the path-only case) —
/// a helper that builds and returns a module directly, rather than just a
/// path — returns the token index of the inner `root_source_file`
/// string literal, exactly as `rootSourceFileOfCreateModule` would for an
/// inline `b.createModule(...)` call.
pub fn rootSourceFileOfHelperFn(
    tree: *const Ast,
    fn_name: []const u8,
    call_buf: *[1]Ast.Node.Index,
    struct_buf: *[2]Ast.Node.Index,
) ?Ast.TokenIndex {
    const fn_decl = findFnDecl(tree, fn_name) orelse return null;
    const body = tree.nodeData(fn_decl).node_and_node[1];

    var stmt_buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&stmt_buf, body) orelse return null;
    if (stmts.len == 0) return null;
    const last = stmts[stmts.len - 1];
    if (tree.nodeTag(last) != .@"return") return null;
    const ret_expr = tree.nodeData(last).opt_node.unwrap() orelse return null;

    return rootSourceFileOfCreateModule(tree, ret_expr, call_buf, struct_buf);
}

/// Finds a `fn <name>(...) ... { ... }` declaration anywhere in `tree`.
fn findFnDecl(tree: *const Ast, name: []const u8) ?Ast.Node.Index {
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(name_tok), name)) return node;
    }
    return null;
}

/// How a `b.path(...)` expression inside a `build.zig` helper reaches the
/// string that names the file: as the helper's own parameter, as a field of
/// a loop capture (`pt.path`), or as a tuple slot of one (`tc[1]`).
const PathAccessor = union(enum) {
    field: []const u8,
    index: u32,
};

/// Which list a resolved root belongs in. `has_executable`/`has_library`
/// are set by the plain `addExecutable`/`addLibrary` scan whether or not
/// the path resolved, so recognizing more roots here can never flip a
/// project into or out of library mode.
const RootKind = enum { test_root, exe_root };

/// Phase 32: if `fn_name` names a local function whose body is `const m =
/// b.createModule(.{ .root_source_file = b.path(<param>) }); ...
/// b.addTest(.{ .root_module = m })`, the index of `<param>` and the kind of
/// root it declares — so the string literal each call site passes there is
/// a root.
///
/// Registering N test files by calling one local helper per file
/// (`addModuleTest(b, opts, "domains/agent/supervision_test.zig", ...)`) is
/// how a large `build.zig` stays readable, and every file registered that
/// way was otherwise an orphan: reachable by no import, declared by no root
/// zigroot could see. The path is a literal at the call site, so nothing
/// needs evaluating — only the hop from argument position to parameter
/// name, which is why resolving it syntactically is sound.
fn rootParamOfLocalHelper(tree: *const Ast, fn_name: []const u8) ?struct { index: usize, kind: RootKind } {
    const fn_decl = findFnDecl(tree, fn_name) orelse return null;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buf, fn_decl) orelse return null;
    const body = tree.nodeData(fn_decl).node_and_node[1];

    var stmt_buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&stmt_buf, body) orelse return null;

    var call_buf: [1]Ast.Node.Index = undefined;
    var struct_buf: [2]Ast.Node.Index = undefined;
    for (stmts) |stmt| {
        const var_decl = tree.fullVarDecl(stmt) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const path_expr = pathExprOfCreateModule(tree, init_node, &call_buf, &struct_buf) orelse continue;
        if (tree.nodeTag(path_expr) != .identifier) continue;

        const module_var = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const kind = rootKindAtModule(tree, stmts, module_var) orelse return null;
        const param = tree.tokenSlice(tree.nodeMainToken(path_expr));
        const index = paramIndexNamed(tree, proto, param) orelse return null;
        return .{ .index = index, .kind = kind };
    }
    return null;
}

/// Phase 32: the same idea one level out — `for (platform_test_files) |pt| {
/// const m = b.createModule(.{ .root_source_file = b.path(pt.path) }); ...
/// b.addTest(.{ .root_module = m }); }`. The table is a comptime literal in
/// the same file, so every path it names can be read straight off the array
/// literal; the loop body only says which field (or tuple slot) of an
/// element holds it. Appends one root per element.
fn scanRootTableLoop(gpa: Allocator, tree: *const Ast, result: *BuildGraph, for_full: Ast.full.For) !void {
    if (for_full.ast.inputs.len == 0) return;
    const table_node = for_full.ast.inputs[0];
    if (tree.nodeTag(table_node) != .identifier) return;
    const table_name = tree.tokenSlice(tree.nodeMainToken(table_node));

    var capture_tok = for_full.payload_token;
    if (tree.tokenTag(capture_tok) == .asterisk) capture_tok += 1;
    const capture = tree.tokenSlice(capture_tok);

    var stmt_buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&stmt_buf, for_full.ast.then_expr) orelse return;

    var call_buf: [1]Ast.Node.Index = undefined;
    var struct_buf: [2]Ast.Node.Index = undefined;
    for (stmts) |stmt| {
        const var_decl = tree.fullVarDecl(stmt) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const path_expr = pathExprOfCreateModule(tree, init_node, &call_buf, &struct_buf) orelse continue;
        const accessor = captureAccessor(tree, path_expr, capture) orelse continue;

        const module_var = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const kind = rootKindAtModule(tree, stmts, module_var) orelse return;
        try appendTableRoots(gpa, tree, result, table_name, accessor, kind);
        return;
    }
}

/// Phase 33: `for (CODEGEN_FRONTENDS) |fe| { codegen.addCodegen(b, ..., fe); }`
/// — a table of option structs forwarded one element at a time to a helper
/// in another file, which roots a module at `b.path(opts.<field>)` and gives
/// it a name. `resolveParamForwardingCall` already closes this loop when the
/// options are written inline at the call site (`wire(b, .{ .routes_src =
/// "..." })`); the only thing missing for the table form is knowing which
/// struct the capture stands for, and the table literal says that for every
/// iteration at once. Without it a routes file reachable *only* as a named
/// module — clusterd's is also imported by path, iamd's isn't — is an orphan.
fn scanTableForwardedModules(
    gpa: Allocator,
    tree: *const Ast,
    result: *BuildGraph,
    for_full: Ast.full.For,
    resolver: ?HelperResolver,
    import_aliases: *const std.StringHashMapUnmanaged(Ast.TokenIndex),
) !void {
    const r = resolver orelse return;
    if (for_full.ast.inputs.len == 0) return;
    const table_node = for_full.ast.inputs[0];
    if (tree.nodeTag(table_node) != .identifier) return;
    const table_name = tree.tokenSlice(tree.nodeMainToken(table_node));

    var capture_tok = for_full.payload_token;
    if (tree.tokenTag(capture_tok) == .asterisk) capture_tok += 1;
    const capture = tree.tokenSlice(capture_tok);

    var stmt_buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&stmt_buf, for_full.ast.then_expr) orelse return;

    var call_buf: [1]Ast.Node.Index = undefined;
    for (stmts) |stmt| {
        var expr = stmt;
        if (tree.fullVarDecl(stmt)) |var_decl| {
            expr = var_decl.ast.init_node.unwrap() orelse continue;
        }
        const call = tree.fullCall(&call_buf, expr) orelse continue;
        if (!callForwardsIdentifier(tree, call, capture)) continue;

        const helper = crossFileHelperCall(tree, call) orelse continue;
        const alias_tok = import_aliases.get(helper.alias) orelse continue;
        try applyTableRequirements(gpa, tree, result, r, alias_tok, helper.fn_name, table_name);
    }
}

/// Whether `call` passes `name` straight through as one of its arguments —
/// the loop capture reaching the helper unchanged, which is what makes the
/// table element and the helper's `opts` parameter the same value.
fn callForwardsIdentifier(tree: *const Ast, call: Ast.full.Call, name: []const u8) bool {
    for (call.ast.params) |param| {
        if (isIdentifierNamed(tree, param, name)) return true;
    }
    return false;
}

/// Records one module per (table element, requirement) pair: the helper named
/// by `alias_tok`/`fn_name` says which option field holds a root source path
/// and what module name it gets, and `table_name`'s literal holds the paths.
fn applyTableRequirements(
    gpa: Allocator,
    tree: *const Ast,
    result: *BuildGraph,
    resolver: HelperResolver,
    alias_tok: Ast.TokenIndex,
    fn_name: []const u8,
    table_name: []const u8,
) !void {
    const rel_path = parseStringLiteral(gpa, tree, alias_tok) catch return;
    defer gpa.free(rel_path);

    const requirements = (resolver.paramRequirements(gpa, rel_path, fn_name) catch return) orelse return;
    defer freeParamRequirements(gpa, requirements);

    const table_init = findVarDeclInit(tree, table_name) orelse return;
    var array_buf: [2]Ast.Node.Index = undefined;
    const table = tree.fullArrayInit(&array_buf, table_init) orelse return;

    for (table.ast.elements) |element| {
        for (requirements) |req| {
            const tok = tableElementPath(tree, element, .{ .field = req.param_field }) orelse continue;
            const path = parseStringLiteral(gpa, tree, tok) catch continue;
            defer gpa.free(path);

            const import_name = try gpa.dupe(u8, req.import_name);
            errdefer gpa.free(import_name);
            try addModulePath(gpa, result, import_name, path);
        }
    }
}

/// Reads every path `table_name`'s literal names through `accessor` and
/// records it as a root of `kind`. A malformed element is skipped rather
/// than failing the table: one entry zigroot can't read shouldn't cost the
/// rest of the table its roots.
fn appendTableRoots(
    gpa: Allocator,
    tree: *const Ast,
    result: *BuildGraph,
    table_name: []const u8,
    accessor: PathAccessor,
    kind: RootKind,
) !void {
    const table_init = findVarDeclInit(tree, table_name) orelse return;
    var array_buf: [2]Ast.Node.Index = undefined;
    const table = tree.fullArrayInit(&array_buf, table_init) orelse return;

    for (table.ast.elements) |element| {
        const tok = tableElementPath(tree, element, accessor) orelse continue;
        const path = parseStringLiteral(gpa, tree, tok) catch continue;
        errdefer gpa.free(path);
        switch (kind) {
            .test_root => try result.test_roots.append(gpa, path),
            .exe_root => try result.exe_roots.append(gpa, path),
        }
    }
}

/// The string-literal token `accessor` selects out of one table element — a
/// named field of a struct literal, or a slot of a tuple literal.
fn tableElementPath(tree: *const Ast, element: Ast.Node.Index, accessor: PathAccessor) ?Ast.TokenIndex {
    switch (accessor) {
        .field => |name| {
            var struct_buf: [2]Ast.Node.Index = undefined;
            const struct_init = tree.fullStructInit(&struct_buf, element) orelse return null;
            for (struct_init.ast.fields) |field_value| {
                const name_tok = tree.firstToken(field_value) - 2;
                if (!std.mem.eql(u8, tree.tokenSlice(name_tok), name)) continue;
                if (tree.nodeTag(field_value) != .string_literal) return null;
                return tree.nodeMainToken(field_value);
            }
            return null;
        },
        .index => |slot| {
            var array_buf: [2]Ast.Node.Index = undefined;
            const array_init = tree.fullArrayInit(&array_buf, element) orelse return null;
            if (slot >= array_init.ast.elements.len) return null;
            const chosen = array_init.ast.elements[slot];
            if (tree.nodeTag(chosen) != .string_literal) return null;
            return tree.nodeMainToken(chosen);
        },
    }
}

/// How `node` reads a path out of `capture`: `capture.field` or
/// `capture[index]`. `null` when `node` isn't rooted at `capture` at all,
/// which is how a loop that builds its paths some other way is left alone.
fn captureAccessor(tree: *const Ast, node: Ast.Node.Index, capture: []const u8) ?PathAccessor {
    switch (tree.nodeTag(node)) {
        .field_access => {
            const base, const name_tok = tree.nodeData(node).node_and_token;
            if (!isIdentifierNamed(tree, base, capture)) return null;
            return .{ .field = tree.tokenSlice(name_tok) };
        },
        .array_access => {
            const base, const index_node = tree.nodeData(node).node_and_node;
            if (!isIdentifierNamed(tree, base, capture)) return null;
            if (tree.nodeTag(index_node) != .number_literal) return null;
            const text = tree.tokenSlice(tree.nodeMainToken(index_node));
            const slot = std.fmt.parseInt(u32, text, 10) catch return null;
            return .{ .index = slot };
        },
        else => return null,
    }
}

fn isIdentifierNamed(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

/// The expression `node` passes to `b.path(...)` for its `root_source_file`,
/// for the `b.createModule(.{ .root_source_file = b.path(<expr>) })` shape —
/// the same extraction as `rootSourceFileFromOptions`, except the path is
/// named indirectly and left for the caller to resolve.
fn pathExprOfCreateModule(
    tree: *const Ast,
    node: Ast.Node.Index,
    call_buf: *[1]Ast.Node.Index,
    struct_buf: *[2]Ast.Node.Index,
) ?Ast.Node.Index {
    const call = tree.fullCall(call_buf, node) orelse return null;
    const field = fieldAccessName(tree, call.ast.fn_expr) orelse return null;
    if (!std.mem.eql(u8, field, "createModule")) return null;
    if (call.ast.params.len < 1) return null;

    const struct_init = tree.fullStructInit(struct_buf, call.ast.params[0]) orelse return null;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_source_file")) continue;

        var path_buf: [1]Ast.Node.Index = undefined;
        const path_call = tree.fullCall(&path_buf, field_value) orelse return null;
        const path_field = fieldAccessName(tree, path_call.ast.fn_expr) orelse return null;
        if (!std.mem.eql(u8, path_field, "path")) return null;
        if (path_call.ast.params.len < 1) return null;
        return path_call.ast.params[0];
    }
    return null;
}

/// What `stmts` builds out of the module bound to `module_var`: a test, an
/// executable, or nothing. Without this check a parameter would be read as
/// a root on the strength of a `createModule` alone, and a module built to
/// be imported rather than compiled would be miscounted.
fn rootKindAtModule(tree: *const Ast, stmts: []const Ast.Node.Index, module_var: []const u8) ?RootKind {
    var call_buf: [1]Ast.Node.Index = undefined;
    var struct_buf: [2]Ast.Node.Index = undefined;
    for (stmts) |stmt| {
        var expr = stmt;
        if (tree.fullVarDecl(stmt)) |var_decl| {
            expr = var_decl.ast.init_node.unwrap() orelse continue;
        }
        const call = tree.fullCall(&call_buf, expr) orelse continue;
        const field = fieldAccessName(tree, call.ast.fn_expr) orelse continue;

        const kind: RootKind = if (std.mem.eql(u8, field, "addTest"))
            .test_root
        else if (std.mem.eql(u8, field, "addExecutable") or std.mem.eql(u8, field, "addLibrary"))
            .exe_root
        else
            continue;

        if (call.ast.params.len < 1) continue;
        if (rootModuleIsNamed(tree, call.ast.params[0], &struct_buf, module_var)) return kind;
    }
    return null;
}

/// Whether `options`, an `addTest`/`addExecutable` argument struct, roots
/// itself at the module bound to `module_var`.
fn rootModuleIsNamed(
    tree: *const Ast,
    options: Ast.Node.Index,
    struct_buf: *[2]Ast.Node.Index,
    module_var: []const u8,
) bool {
    const struct_init = tree.fullStructInit(struct_buf, options) orelse return false;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_module")) continue;
        return isIdentifierNamed(tree, field_value, module_var);
    }
    return false;
}

/// The initializer of a `const <name> = ...` declaration anywhere in `tree`.
fn findVarDeclInit(tree: *const Ast, name: []const u8) ?Ast.Node.Index {
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        const var_decl = tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(var_decl.ast.mut_token + 1), name)) continue;
        return var_decl.ast.init_node.unwrap();
    }
    return null;
}

/// Records `import_name -> rel_path` in `result.modules`, taking ownership
/// of `import_name` and copying `rel_path`. Dedupes candidates already
/// recorded for the same name.
fn addModulePath(gpa: Allocator, result: *BuildGraph, import_name: []u8, rel_path: []const u8) !void {
    const gop = try result.modules.getOrPut(gpa, import_name);
    if (gop.found_existing) {
        gpa.free(import_name);
    } else {
        gop.key_ptr.* = import_name;
        gop.value_ptr.* = .empty;
    }

    const dup_path = try gpa.dupe(u8, rel_path);
    errdefer gpa.free(dup_path);
    for (gop.value_ptr.items) |existing| {
        if (std.mem.eql(u8, existing, dup_path)) {
            gpa.free(dup_path);
            return;
        }
    }
    try gop.value_ptr.append(gpa, dup_path);
}

/// Scans an `.imports = &.{ .{ .name = "...", .module = <ident> }, ... }`
/// options-struct field (the inline alternative to chained `addImport`
/// calls), binding each string name to the path already recorded for its
/// `.module` identifier in `bindings`.
fn scanImportsField(
    gpa: Allocator,
    tree: *const Ast,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
    field_bindings: *const std.StringHashMapUnmanaged([]const u8),
    result: *BuildGraph,
    field_value: Ast.Node.Index,
) !void {
    const inner = if (tree.nodeTag(field_value) == .address_of)
        tree.nodeData(field_value).node
    else
        field_value;

    var array_buf: [2]Ast.Node.Index = undefined;
    const array_init = tree.fullArrayInit(&array_buf, inner) orelse return;

    var entry_buf: [2]Ast.Node.Index = undefined;
    for (array_init.ast.elements) |elem| {
        const entry = tree.fullStructInit(&entry_buf, elem) orelse continue;

        var import_name: ?[]u8 = null;
        var module_path: ?[]const u8 = null;
        for (entry.ast.fields) |entry_field| {
            const name_tok = tree.firstToken(entry_field) - 2;
            const field_name = tree.tokenSlice(name_tok);
            if (std.mem.eql(u8, field_name, "name")) {
                if (tree.nodeTag(entry_field) != .string_literal) continue;
                import_name = parseStringLiteral(gpa, tree, tree.nodeMainToken(entry_field)) catch null;
            } else if (std.mem.eql(u8, field_name, "module")) {
                module_path = pathForBinding(tree, bindings, field_bindings, entry_field);
            }
        }

        const name = import_name orelse continue;
        const path = module_path orelse {
            try addExternalName(gpa, result, name);
            continue;
        };
        try addModulePath(gpa, result, name, path);
    }
}

/// Resolves `value_node` (an `addImport` second argument, or an `.imports`
/// entry's `.module` field) to a `root_source_file` path: either a bare
/// identifier bound by a previously-recorded `createModule`/`b.path` binding
/// in `bindings`, or a field access (`mods.foo`) into a struct a local
/// helper function returned, recorded in `field_bindings` by
/// `bindStructReturnFields`.
///
/// A field access with no `field_bindings` entry falls back to `bindings`
/// keyed by the field name alone: a build.zig split into stratified helpers
/// (`fn wireAuth(b, fnd: Foundation)` doing `x.addImport("storage",
/// fnd.storage)`) references the struct through a *parameter*, and the
/// single flat scan meets that body before the caller's `const fnd =
/// wireFoundation(b)` binds `fnd.storage`. The field name is the same
/// `createModule` variable the returning helper bound file-wide, so this is
/// the same name-keyed over-approximation `bindings` already makes.
fn pathForBinding(
    tree: *const Ast,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
    field_bindings: *const std.StringHashMapUnmanaged([]const u8),
    value_node: Ast.Node.Index,
) ?[]const u8 {
    switch (tree.nodeTag(value_node)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(value_node));
            return bindings.get(name);
        },
        .field_access => {
            const base_node = tree.nodeData(value_node).node_and_token[0];
            if (tree.nodeTag(base_node) != .identifier) return null;
            const base = tree.tokenSlice(tree.nodeMainToken(base_node));
            const field = fieldAccessName(tree, value_node) orelse return null;

            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ base, field }) catch return null;
            if (field_bindings.get(key)) |path| return path;
            return bindings.get(field);
        },
        else => return null,
    }
}

/// If `call` is a call to a locally-defined function (a plain identifier
/// callee — e.g. `wireModules(b)`, not `b.method(...)`) whose body's last
/// statement is `return .{ .foo = foo, ... };` — a helper that builds
/// several related modules and returns them bundled in a struct (see
/// issues/35) — binds `"<var_name>.<field>" -> path` in `field_bindings`
/// for every returned field whose value resolves via `pathForBinding`
/// against `bindings` as already accumulated by this scan. Relies on the
/// helper being scanned (and its own `createModule`/`addModule` bindings
/// recorded) before its call site is reached, true for the typical
/// helper-defined-before-use style.
fn bindStructReturnFields(
    gpa: Allocator,
    tree: *const Ast,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
    field_bindings: *std.StringHashMapUnmanaged([]const u8),
    var_name: []const u8,
    call: Ast.full.Call,
    struct_buf: *[2]Ast.Node.Index,
) !void {
    if (tree.nodeTag(call.ast.fn_expr) != .identifier) return;
    const fn_name = tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr));
    const fn_decl = findFnDecl(tree, fn_name) orelse return;

    var proto_buf: [1]Ast.Node.Index = undefined;
    _ = tree.fullFnProto(&proto_buf, fn_decl) orelse return;
    const body = tree.nodeData(fn_decl).node_and_node[1];

    var stmt_buf: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&stmt_buf, body) orelse return;
    if (stmts.len == 0) return;
    const last = stmts[stmts.len - 1];
    if (tree.nodeTag(last) != .@"return") return;
    const ret_expr = tree.nodeData(last).opt_node.unwrap() orelse return;

    const struct_init = tree.fullStructInit(struct_buf, ret_expr) orelse return;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        const field_name = tree.tokenSlice(name_tok);
        const path = pathForBinding(tree, bindings, field_bindings, field_value) orelse continue;

        const key = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ var_name, field_name });
        errdefer gpa.free(key);
        try putFieldBinding(gpa, field_bindings, key, path);
    }
}

/// Records `key -> path` (a `dupe`d copy of `path`) in `field_bindings`,
/// taking ownership of `key`. Unlike `putBinding`, both key and value are
/// owned here — `field_bindings`' entries never borrow from `tree`.
fn putFieldBinding(
    gpa: Allocator,
    field_bindings: *std.StringHashMapUnmanaged([]const u8),
    key: []u8,
    path: []const u8,
) !void {
    const dup_path = try gpa.dupe(u8, path);
    errdefer gpa.free(dup_path);

    const gop = try field_bindings.getOrPut(gpa, key);
    if (gop.found_existing) {
        gpa.free(key);
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = key;
    }
    gop.value_ptr.* = dup_path;
}

/// If `node` is a `field_access` (`lhs.name`), returns `name`.
fn fieldAccessName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .field_access) return null;
    const data = tree.nodeData(node).node_and_token;
    return tree.tokenSlice(data[1]);
}

/// Binds `var_name` to `path` in `bindings`, freeing whatever `path` it
/// previously owned first. Local variable names aren't unique across a
/// `build.zig`'s sibling blocks (e.g. `{ const m = ...; ... }` repeated per
/// `b.addTest`, each `m` scoped to its own block but sharing this flat,
/// scope-unaware map) — without this, a later shadowing bind would leak
/// the earlier one's `path`.
fn putBinding(gpa: Allocator, bindings: *std.StringHashMapUnmanaged([]const u8), var_name: []const u8, path: []const u8) !void {
    const gop = try bindings.getOrPut(gpa, var_name);
    if (gop.found_existing) gpa.free(gop.value_ptr.*);
    gop.value_ptr.* = path;
}

pub fn parseStringLiteral(gpa: Allocator, tree: *const Ast, token: Ast.TokenIndex) ![]u8 {
    const raw = tree.tokenSlice(token);
    return std.zig.string_literal.parseAlloc(gpa, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStringLiteral,
    };
}
