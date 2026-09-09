//! One parsed and semantically-analyzed source file inside a `Project`.
//!
//! `File` owns the source buffer that `semantic` points into, so the two
//! must be torn down together (`deinit`), in that order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlint = @import("zlint");

const FileId = @import("FileId.zig").FileId;

const File = @This();

id: FileId,
/// Canonicalized, absolute path. Owned.
path: []const u8,
/// Sentinel-terminated source text `semantic` was parsed from. Owned.
/// Must outlive `semantic`.
source: [:0]u8,
semantic: zlint.Semantic,

/// Reads `path` from disk, parses it, and runs ZLint's semantic builder
/// over it. `path` must already be resolved (see `Project.resolvePath`);
/// it is duplicated into the returned `File`.
pub fn load(gpa: Allocator, id: FileId, path: []const u8) !File {
    const source = try readFileSentinel(gpa, path);
    errdefer gpa.free(source);

    var builder = zlint.Semantic.Builder.init(gpa);
    defer builder.deinit();

    var result = try builder.build(source);
    errdefer result.value.deinit();
    result.errors.deinit(gpa);

    return .{
        .id = id,
        .path = try gpa.dupe(u8, path),
        .source = source,
        .semantic = result.value,
    };
}

pub fn deinit(self: *File, gpa: Allocator) void {
    self.semantic.deinit();
    gpa.free(self.source);
    gpa.free(self.path);
    self.* = undefined;
}

fn readFileSentinel(gpa: Allocator, path: []const u8) ![:0]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try gpa.allocSentinel(u8, @intCast(stat.size), 0);
    errdefer gpa.free(buf);
    const n = try file.readAll(buf);
    if (n != buf.len) return error.UnexpectedEndOfFile;
    return buf;
}
