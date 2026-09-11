//! The parts of a `build.zig.zon` the analyzer needs: the set of
//! dependency names (so `@import("dep")` is an external package, never a
//! configuration gap and never dead code) and, for each `.path = "..."`
//! dependency, the directory to keep out of orphan-file discovery (it's
//! another package's source tree, not this project's).
//!
//! Read syntactically with `std.zig.Ast` in `.zon` mode rather than
//! `std.zon.parse`: `.dependencies` is a map with arbitrary keys, which a
//! typed parse can't express, and this only needs two fields anyway.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const ZonFile = @This();

/// Every key of `.dependencies`. Owned.
dependencies: std.ArrayListUnmanaged([]const u8) = .empty,
/// The `.path` value of every path dependency, relative to the directory
/// holding the `build.zig.zon`. Owned.
path_dependencies: std.ArrayListUnmanaged([]const u8) = .empty,

pub const empty: ZonFile = .{};

pub fn deinit(self: *ZonFile, gpa: Allocator) void {
    for (self.dependencies.items) |name| gpa.free(name);
    self.dependencies.deinit(gpa);
    for (self.path_dependencies.items) |path| gpa.free(path);
    self.path_dependencies.deinit(gpa);
    self.* = undefined;
}

pub fn isDependency(self: *const ZonFile, name: []const u8) bool {
    for (self.dependencies.items) |dep| {
        if (std.mem.eql(u8, dep, name)) return true;
    }
    return false;
}

/// Parses `source` (the text of a `build.zig.zon`). A file that doesn't
/// parse, or that has no `.dependencies`, yields an empty `ZonFile` rather
/// than an error: a broken manifest is `zig build`'s problem to report,
/// and the analysis is still meaningful without it.
pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!ZonFile {
    var result: ZonFile = .empty;
    errdefer result.deinit(gpa);

    var tree = Ast.parse(gpa, source, .zon) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return result;

    const root_decls = tree.rootDecls();
    if (root_decls.len == 0) return result;

    var root_buf: [2]Ast.Node.Index = undefined;
    const root_init = tree.fullStructInit(&root_buf, root_decls[0]) orelse return result;

    for (root_init.ast.fields) |field_value| {
        const field_name = fieldName(&tree, field_value) orelse continue;
        if (!std.mem.eql(u8, field_name, "dependencies")) continue;

        var deps_buf: [2]Ast.Node.Index = undefined;
        const deps_init = tree.fullStructInit(&deps_buf, field_value) orelse continue;
        for (deps_init.ast.fields) |dep_value| {
            const dep_name = fieldName(&tree, dep_value) orelse continue;
            try result.dependencies.append(gpa, try gpa.dupe(u8, dep_name));

            var dep_buf: [2]Ast.Node.Index = undefined;
            const dep_init = tree.fullStructInit(&dep_buf, dep_value) orelse continue;
            for (dep_init.ast.fields) |dep_field| {
                const dep_field_name = fieldName(&tree, dep_field) orelse continue;
                if (!std.mem.eql(u8, dep_field_name, "path")) continue;
                if (tree.nodeTag(dep_field) != .string_literal) continue;
                const raw = tree.tokenSlice(tree.nodeMainToken(dep_field));
                const path = std.zig.string_literal.parseAlloc(gpa, raw) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                try result.path_dependencies.append(gpa, path);
            }
        }
    }

    return result;
}

/// The name of the struct-init field whose value is `value_node`: the
/// identifier two tokens before the value (`.name = value`), with `@"..."`
/// quoting stripped.
fn fieldName(tree: *const Ast, value_node: Ast.Node.Index) ?[]const u8 {
    const first = tree.firstToken(value_node);
    if (first < 2) return null;
    const name_tok = first - 2;
    if (tree.tokenTag(name_tok) != .identifier) return null;
    const raw = tree.tokenSlice(name_tok);
    if (std.mem.startsWith(u8, raw, "@\"") and raw.len >= 3) return raw[2 .. raw.len - 1];
    return raw;
}
