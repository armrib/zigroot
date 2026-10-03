//! The surface a project publishes to consumers this analysis cannot see.
//!
//! Some code is called only from outside the project being analyzed: a
//! wire-format codec three sibling demos import by path, a symbol a
//! generated SDK resolves by name. No amount of inference finds those
//! callers — they are not in the file set — and the alternative, writing
//! `comptime { _ = Foo.bar; }` in the source, is a declaration that exists
//! only to quiet a tool.
//!
//! So the project states the contract instead, in a `.zigroot.zon` beside
//! its `build.zig`:
//!
//! ```zig
//! .{
//!     .exports = .{
//!         // Called by sdks/db/zig/codegen.zig, which db never builds.
//!         "src/catalog/catalog.zig:typeByName",
//!         // Whole-file form: every `pub` declaration is API.
//!         "src/proto_root.zig",
//!     },
//! }
//! ```
//!
//! An entry naming a file or symbol that doesn't exist is an error, not a
//! silent no-op: a contract nobody checks rots into exactly the baseline
//! this tool refuses to keep.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const FieldChain = @import("FieldChain.zig");
const OwnerMap = @import("OwnerMap.zig");
const Semantic = @import("semantic/Semantic.zig");

const ExportContract = @This();

pub const Entry = struct {
    /// The whole `path[:symbol]` string, and the only owned allocation:
    /// `path` and `symbol` are slices of it.
    spec: []const u8,
    /// Path relative to the directory holding the `.zigroot.zon`.
    path: []const u8,
    /// The declaration named — bare (`decl`) or qualified (`Outer.inner`) —
    /// or `null` for every `pub` one.
    symbol: ?[]const u8,
};

entries: std.ArrayListUnmanaged(Entry) = .empty,

pub const empty: ExportContract = .{};

pub fn deinit(self: *ExportContract, gpa: Allocator) void {
    for (self.entries.items) |entry| gpa.free(entry.spec);
    self.entries.deinit(gpa);
    self.* = undefined;
}

/// Parses `source`, the text of a `.zigroot.zon`. A file that doesn't parse
/// yields no entries; `zig`'s own diagnostics are better than anything this
/// syntactic read could say.
pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!ExportContract {
    var result: ExportContract = .empty;
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
        if (!std.mem.eql(u8, field_name, "exports")) continue;

        var list_buf: [2]Ast.Node.Index = undefined;
        const list = tree.fullArrayInit(&list_buf, field_value) orelse continue;
        for (list.ast.elements) |element| {
            if (tree.nodeTag(element) != .string_literal) continue;
            const raw = tree.tokenSlice(tree.nodeMainToken(element));
            const spec = std.zig.string_literal.parseAlloc(gpa, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            errdefer gpa.free(spec);
            try result.entries.append(gpa, split(spec));
        }
    }

    return result;
}

/// Splits `path:symbol` into its two halves, in place. A spec with no colon
/// is the whole-file form.
fn split(spec: []const u8) Entry {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse
        return .{ .spec = spec, .path = spec, .symbol = null };
    return .{ .spec = spec, .path = spec[0..colon], .symbol = spec[colon + 1 ..] };
}

/// The name of the struct-init field whose value is `value_node` — see
/// `ZonFile.fieldName`, which reads the same shape.
fn fieldName(tree: *const Ast, value_node: Ast.Node.Index) ?[]const u8 {
    const first = tree.firstToken(value_node);
    if (first < 2) return null;
    const name_tok = first - 2;
    if (tree.tokenTag(name_tok) != .identifier) return null;
    const raw = tree.tokenSlice(name_tok);
    if (std.mem.startsWith(u8, raw, "@\"") and raw.len >= 3) return raw[2 .. raw.len - 1];
    return raw;
}

/// What an entry's `symbol` names inside one loaded file.
pub const Lookup = union(enum) {
    found: Semantic.Symbol.Id,
    /// The first segment of `symbol` that names nothing — the whole name for
    /// the bare form. Borrows the entry's `spec`.
    missing: []const u8,
};

/// Bounds a qualified name's depth; no real container nests this deep.
const segment_count_max: u32 = 64;

/// Every file's top-level declarations are exported from symbol 0, the one
/// ZLint's `SemanticBuilder.enterRoot` creates first.
const file_root_symbol: Semantic.Symbol.Id = @enumFromInt(0);

/// Resolves `symbol` in `semantic`. A bare name matches any declaration of
/// that name in the file; a dotted `Outer.inner` walks container members
/// from the file root, so two same-named methods can be told apart.
pub fn lookup(semantic: *const Semantic, owner_map: *const OwnerMap, symbol: []const u8) Lookup {
    std.debug.assert(symbol.len > 0);
    if (std.mem.indexOfScalar(u8, symbol, '.') == null) {
        const named = semantic.symbols.getSymbolNamed(symbol) orelse return .{ .missing = symbol };
        return .{ .found = named };
    }

    var container = file_root_symbol;
    var segments = std.mem.splitScalar(u8, symbol, '.');
    var segment_count: u32 = 0;
    while (segments.next()) |segment| {
        segment_count += 1;
        if (segment_count > segment_count_max) return .{ .missing = segment };
        if (segment.len == 0) return .{ .missing = segment };
        container = FieldChain.findExport(semantic, owner_map, container, segment) orelse
            return .{ .missing = segment };
    }
    std.debug.assert(segment_count >= 2);
    std.debug.assert(container != file_root_symbol);
    return .{ .found = container };
}
