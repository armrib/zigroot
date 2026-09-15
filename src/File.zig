//! One parsed and semantically-analyzed source file inside a `Project`.
//!
//! `File` owns the source buffer that `semantic` points into, so the two
//! must be torn down together (`deinit`), in that order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");

const FileId = @import("FileId.zig").FileId;
const OwnerMap = @import("OwnerMap.zig");
const SymbolGraph = @import("SymbolGraph.zig");

const File = @This();

id: FileId,
/// Canonicalized, absolute path. Owned.
path: []const u8,
/// Sentinel-terminated source text `semantic` was parsed from. Owned.
/// Must outlive `semantic`.
source: [:0]u8,
semantic: Semantic,
/// Node -> containing-declaration map, built from `semantic`. See
/// `OwnerMap`.
owner_map: OwnerMap,
/// Same-file `Symbol -> Symbol` reference edges, built from `semantic`
/// and `owner_map`. See `SymbolGraph`.
symbol_graph: SymbolGraph,
/// Phase 38: true for a file reached only through test code. Its own
/// declarations are not findings, and everything it references is a test
/// root rather than a production one — it *is* test code, wholesale.
test_only: bool = false,
/// Parse and semantic-analysis diagnostics the builder reported for this
/// file. A file with any of these has a partial symbol table (the parser
/// recovers as best it can), so its dead-symbol findings can't be trusted;
/// the CLI prints them and exits non-zero. Owned.
errors: std.ArrayListUnmanaged(Semantic.Error),

/// Reads `path` from disk, parses it, and runs ZLint's semantic builder
/// over it. `path` must already be resolved (see `Project.resolvePath`);
/// it is duplicated into the returned `File`.
pub fn load(gpa: Allocator, id: FileId, path: []const u8) !File {
    const source = try readFileSentinel(gpa, path);
    errdefer gpa.free(source);

    var builder = Semantic.Builder.init(gpa);
    defer builder.deinit();

    var result = try builder.build(source);
    errdefer result.value.deinit();
    errdefer result.deinitErrors();

    var owner_map = try OwnerMap.build(gpa, &result.value);
    errdefer owner_map.deinit(gpa);

    var symbol_graph = try SymbolGraph.build(gpa, id, &result.value, &owner_map);
    errdefer symbol_graph.deinit(gpa);

    return .{
        .id = id,
        .path = try gpa.dupe(u8, path),
        .source = source,
        .semantic = result.value,
        .owner_map = owner_map,
        .symbol_graph = symbol_graph,
        .errors = result.errors,
    };
}

pub fn deinit(self: *File, gpa: Allocator) void {
    for (self.errors.items) |*err| err.deinit(gpa);
    self.errors.deinit(gpa);
    self.symbol_graph.deinit(gpa);
    self.owner_map.deinit(gpa);
    self.semantic.deinit();
    gpa.free(self.source);
    gpa.free(self.path);
    self.* = undefined;
}

pub fn readFileSentinel(gpa: Allocator, path: []const u8) ![:0]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try gpa.allocSentinel(u8, @intCast(stat.size), 0);
    errdefer gpa.free(buf);
    const n = try file.readAll(buf);
    if (n != buf.len) return error.UnexpectedEndOfFile;
    return buf;
}
