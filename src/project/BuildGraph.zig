//! Best-effort extraction of a `build.zig`'s local module graph: which
//! `@import("name")` module specifiers resolve to a file on disk, per the
//! `const x = b.createModule(.{ .root_source_file = b.path("...") });`
//! + `<module>.addImport("name", x);` shape used to wire modules together.
//!
//! This is a syntactic scan over `build.zig`'s AST, not a real evaluation
//! of the build script (that would require running it). Modules that come
//! from `b.dependency(...).module(...)` aren't backed by a local file and
//! are left unresolved, same as before this phase existed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const BuildGraph = @This();

/// import name -> root source file path, relative to the `build.zig`'s
/// directory. Owned (both keys and values).
modules: std.StringHashMapUnmanaged([]const u8) = .empty,

pub const empty: BuildGraph = .{};

pub fn deinit(self: *BuildGraph, gpa: Allocator) void {
    var it = self.modules.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    self.modules.deinit(gpa);
    self.* = undefined;
}

pub fn resolve(self: *const BuildGraph, name: []const u8) ?[]const u8 {
    return self.modules.get(name);
}

/// Parses `source` (a `build.zig`'s contents) and extracts its local
/// module bindings. `source` need not be error-free; a `build.zig` with
/// parse errors just yields an empty or partial graph.
pub fn parse(gpa: Allocator, source: [:0]const u8) !BuildGraph {
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    // local variable name -> root_source_file path (borrowed from `tree`).
    var bindings: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer bindings.deinit(gpa);

    var result: BuildGraph = .empty;
    errdefer result.deinit(gpa);

    var call_buf: [1]Ast.Node.Index = undefined;
    var struct_buf: [2]Ast.Node.Index = undefined;

    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);

        if (tree.fullVarDecl(node)) |var_decl| {
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            if (rootSourceFileOfCreateModule(&tree, init_node, &call_buf, &struct_buf)) |rel_path| {
                const name_tok = var_decl.ast.mut_token + 1;
                const name = tree.tokenSlice(name_tok);
                const path = parseStringLiteral(gpa, &tree, rel_path) catch continue;
                errdefer gpa.free(path);
                try bindings.put(gpa, name, path);
            }
            continue;
        }

        const call = tree.fullCall(&call_buf, node) orelse continue;
        const field = fieldAccessName(&tree, call.ast.fn_expr) orelse continue;
        if (!std.mem.eql(u8, field, "addImport")) continue;
        if (call.ast.params.len < 2) continue;

        const name_node = call.ast.params[0];
        if (tree.nodeTag(name_node) != .string_literal) continue;
        const import_name = parseStringLiteral(gpa, &tree, tree.nodeMainToken(name_node)) catch continue;
        errdefer gpa.free(import_name);

        const value_node = call.ast.params[1];
        const rel_path = pathForBinding(&tree, &bindings, value_node) orelse {
            gpa.free(import_name);
            continue;
        };

        const gop = try result.modules.getOrPut(gpa, import_name);
        if (gop.found_existing) {
            gpa.free(import_name);
            gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = import_name;
        }
        gop.value_ptr.* = try gpa.dupe(u8, rel_path);
    }

    // `bindings`' values are owned by `result` iff still referenced; free
    // whichever weren't picked up by an `addImport`.
    var bit = bindings.iterator();
    while (bit.next()) |entry| gpa.free(entry.value_ptr.*);

    return result;
}

/// If `node` is `<ident>.createModule(.{ ..., .root_source_file =
/// b.path("...") , ... })`, returns the token index of that inner string
/// literal.
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

    const options = call.ast.params[0];
    const struct_init = tree.fullStructInit(struct_buf, options) orelse return null;
    for (struct_init.ast.fields) |field_value| {
        const name_tok = tree.firstToken(field_value) - 2;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "root_source_file")) continue;
        var inner_buf: [1]Ast.Node.Index = undefined;
        const path_call = tree.fullCall(&inner_buf, field_value) orelse return null;
        const path_field = fieldAccessName(tree, path_call.ast.fn_expr) orelse return null;
        if (!std.mem.eql(u8, path_field, "path")) return null;
        if (path_call.ast.params.len < 1) return null;
        const arg = path_call.ast.params[0];
        if (tree.nodeTag(arg) != .string_literal) return null;
        return tree.nodeMainToken(arg);
    }
    return null;
}

/// Resolves `value_node` (an `addImport` second argument) to a
/// `root_source_file` path, if it's a reference to a previously-recorded
/// `createModule` binding.
fn pathForBinding(
    tree: *const Ast,
    bindings: *const std.StringHashMapUnmanaged([]const u8),
    value_node: Ast.Node.Index,
) ?[]const u8 {
    if (tree.nodeTag(value_node) != .identifier) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(value_node));
    return bindings.get(name);
}

/// If `node` is a `field_access` (`lhs.name`), returns `name`.
fn fieldAccessName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .field_access) return null;
    const data = tree.nodeData(node).node_and_token;
    return tree.tokenSlice(data[1]);
}

fn parseStringLiteral(gpa: Allocator, tree: *const Ast, token: Ast.TokenIndex) ![]u8 {
    const raw = tree.tokenSlice(token);
    return std.zig.string_literal.parseAlloc(gpa, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStringLiteral,
    };
}
