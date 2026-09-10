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

pub const empty: BuildGraph = .{};

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
    self.* = undefined;
}

/// Returns every candidate root source file path `name` resolves to, or
/// `null` if `name` isn't a locally-created module.
pub fn resolve(self: *const BuildGraph, name: []const u8) ?[]const []const u8 {
    const paths = self.modules.getPtr(name) orelse return null;
    return paths.items;
}

/// Parses `source` (a `build.zig`'s contents) and extracts its local
/// module bindings. `source` need not be error-free; a `build.zig` with
/// parse errors just yields an empty or partial graph. Doesn't follow
/// local `@import("*.zig")`s into sibling files — see `parseInto` for
/// that (this is a thin single-file wrapper around it, kept for callers
/// — and existing tests — that only care about one file).
pub fn parse(gpa: Allocator, source: [:0]const u8) !BuildGraph {
    var result: BuildGraph = .empty;
    errdefer result.deinit(gpa);

    var file_imports: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (file_imports.items) |p| gpa.free(p);
        file_imports.deinit(gpa);
    }

    try parseInto(gpa, &result, source, &file_imports);
    return result;
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
/// contributes nothing.
pub fn parseInto(
    gpa: Allocator,
    result: *BuildGraph,
    source: [:0]const u8,
    file_imports: *std.ArrayListUnmanaged([]u8),
) !void {
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    // local variable name -> root_source_file path (borrowed from `tree`).
    var bindings: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer bindings.deinit(gpa);

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

    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);

        if (tree.fullVarDecl(node)) |var_decl| {
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            const var_name_tok = var_decl.ast.mut_token + 1;
            const var_name = tree.tokenSlice(var_name_tok);

            if (rootSourceFileOfCreateModule(&tree, init_node, &call_buf, &struct_buf)) |rel_path| {
                const path = parseStringLiteral(gpa, &tree, rel_path) catch continue;
                errdefer gpa.free(path);
                try putBinding(gpa, &bindings, var_name, path);
                continue;
            }

            if (tree.fullCall(&call_buf, init_node)) |call| {
                if (nameAndRootSourceFileOfAddModule(&tree, call, &struct_buf)) |found| {
                    const path = parseStringLiteral(gpa, &tree, found.path) catch continue;
                    errdefer gpa.free(path);
                    try putBinding(gpa, &bindings, var_name, path);
                    continue;
                }

                try bindStructReturnFields(gpa, &tree, &bindings, &field_bindings, var_name, call, &struct_buf);
            }

            if (localFileImportPath(&tree, init_node)) |path_tok| {
                const path = parseStringLiteral(gpa, &tree, path_tok) catch continue;
                errdefer gpa.free(path);
                try file_imports.append(gpa, path);
            }
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

        const call = tree.fullCall(&call_buf, node) orelse continue;
        const field = fieldAccessName(&tree, call.ast.fn_expr) orelse continue;

        if (std.mem.eql(u8, field, "addTest")) {
            if (call.ast.params.len >= 1) {
                if (try testRootFromOptions(gpa, &tree, &bindings, call.ast.params[0], &struct_buf, &call_buf)) |path| {
                    errdefer gpa.free(path);
                    try result.test_roots.append(gpa, path);
                }
            }
            continue;
        }

        if (std.mem.eql(u8, field, "addModule")) {
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

        if (!std.mem.eql(u8, field, "addImport")) continue;
        if (call.ast.params.len < 2) continue;

        const name_node = call.ast.params[0];
        if (tree.nodeTag(name_node) != .string_literal) continue;
        const import_name = parseStringLiteral(gpa, &tree, tree.nodeMainToken(name_node)) catch continue;
        errdefer gpa.free(import_name);

        const value_node = call.ast.params[1];
        const rel_path = pathForBinding(&tree, &bindings, &field_bindings, value_node) orelse {
            gpa.free(import_name);
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
/// helper call in its place, see `pathThroughHelperCall`) in `options` — a
/// `.{ ... }` struct-literal node — and returns the token index of the
/// string literal it resolves to.
fn rootSourceFileFromOptions(tree: *const Ast, options: Ast.Node.Index, struct_buf: *[2]Ast.Node.Index) ?Ast.TokenIndex {
    const struct_init = tree.fullStructInit(struct_buf, options) orelse return null;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_source_file")) continue;
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

/// If `options` (a `b.addTest(.{ ... })` call's first argument) is either
/// the older `.{ .root_source_file = b.path("...") }` shape (delegated to
/// `rootSourceFileFromOptions`) or the current `.{ .root_module = <module>
/// }` shape — `<module>` a local variable bound to a `createModule` call
/// found earlier in the same scan, or an inline `b.createModule(...)` call
/// — returns that module's root source file path, freshly allocated.
/// `null` if neither shape matches, or the path couldn't be resolved.
fn testRootFromOptions(
    gpa: Allocator,
    tree: *const Ast,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
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

        if (tree.nodeTag(field_value) == .identifier) {
            const name = tree.tokenSlice(tree.nodeMainToken(field_value));
            const path = bindings.get(name) orelse return null;
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

    var it = proto.iterate(tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        const name_tok = param.name_token orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(name_tok), arg_name)) return index;
    }
    return null;
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
            gpa.free(name);
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
            return field_bindings.get(key);
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

fn parseStringLiteral(gpa: Allocator, tree: *const Ast, token: Ast.TokenIndex) ![]u8 {
    const raw = tree.tokenSlice(token);
    return std.zig.string_literal.parseAlloc(gpa, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStringLiteral,
    };
}
