//! Parsing a `.zigroot.zon` export contract.

const std = @import("std");
const t = std.testing;
const ExportContract = @import("ExportContract.zig");

test "an export contract reads whole-file and single-symbol entries" {
    var contract = try ExportContract.parse(t.allocator,
        \\.{
        \\    .exports = .{
        \\        "src/proto_root.zig",
        \\        "src/catalog/catalog.zig:typeByName",
        \\    },
        \\}
        \\
    );
    defer contract.deinit(t.allocator);

    try t.expectEqual(@as(usize, 2), contract.entries.items.len);

    try t.expectEqualStrings("src/proto_root.zig", contract.entries.items[0].path);
    try t.expect(contract.entries.items[0].symbol == null);

    try t.expectEqualStrings("src/catalog/catalog.zig", contract.entries.items[1].path);
    try t.expectEqualStrings("typeByName", contract.entries.items[1].symbol.?);
}

test "a missing or unparseable contract yields no entries rather than an error" {
    var empty = try ExportContract.parse(t.allocator, ".{ .exports = .{} }");
    defer empty.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), empty.entries.items.len);

    var broken = try ExportContract.parse(t.allocator, ".{ .exports = ");
    defer broken.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), broken.entries.items.len);
}

const OwnerMap = @import("OwnerMap.zig");
const Semantic = @import("semantic/Semantic.zig");

fn build_semantic(source: [:0]const u8) !Semantic {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();
    var result = try builder.build(source);
    result.errors.deinit(t.allocator);
    return result.value;
}

const two_opens =
    \\pub const Stream = struct {
    \\    pub fn open() void {}
    \\};
    \\pub const Upload = struct {
    \\    pub const Part = struct {
    \\        pub fn open() void {}
    \\    };
    \\    pub fn open() void {}
    \\};
    \\
;

test "a qualified entry resolves the nested declaration, not a same-named sibling" {
    var semantic = try build_semantic(two_opens);
    defer semantic.deinit();
    var owner_map = try OwnerMap.build(t.allocator, &semantic);
    defer owner_map.deinit(t.allocator);

    const upload_open = ExportContract.lookup(&semantic, &owner_map, "Upload.open").found;
    const stream_open = ExportContract.lookup(&semantic, &owner_map, "Stream.open").found;
    const part_open = ExportContract.lookup(&semantic, &owner_map, "Upload.Part.open").found;
    try t.expect(upload_open != stream_open);
    try t.expect(upload_open != part_open);

    const upload = semantic.symbols.getSymbolNamed("Upload").?;
    var found_in_upload = false;
    for (semantic.symbols.getExports(upload).items) |id| {
        if (id == upload_open) found_in_upload = true;
    }
    try t.expect(found_in_upload);
}

test "a bare entry still matches by name anywhere in the file" {
    var semantic = try build_semantic(two_opens);
    defer semantic.deinit();
    var owner_map = try OwnerMap.build(t.allocator, &semantic);
    defer owner_map.deinit(t.allocator);

    const bare = ExportContract.lookup(&semantic, &owner_map, "open");
    try t.expectEqual(semantic.symbols.getSymbolNamed("open").?, bare.found);
    try t.expectEqualStrings("gone", ExportContract.lookup(&semantic, &owner_map, "gone").missing);
}

test "an unknown qualified entry names the first missing segment" {
    var semantic = try build_semantic(two_opens);
    defer semantic.deinit();
    var owner_map = try OwnerMap.build(t.allocator, &semantic);
    defer owner_map.deinit(t.allocator);

    const inner = ExportContract.lookup(&semantic, &owner_map, "Upload.close");
    try t.expectEqualStrings("close", inner.missing);
    const outer = ExportContract.lookup(&semantic, &owner_map, "Download.open");
    try t.expectEqualStrings("Download", outer.missing);
    const empty_segment = ExportContract.lookup(&semantic, &owner_map, "Upload..open");
    try t.expectEqualStrings("", empty_segment.missing);
}
