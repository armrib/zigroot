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
