const std = @import("std");
const t = std.testing;
const ZonFile = @import("ZonFile.zig");

test "collects dependency names and path-dependency directories" {
    var zon = try ZonFile.parse(t.allocator,
        \\.{
        \\    .name = .demo,
        \\    .version = "0.0.0",
        \\    .dependencies = .{
        \\        .zlint = .{ .path = "vendor/zlint" },
        \\        .@"smart-pointers" = .{
        \\            .url = "https://example.invalid/sp.tar.gz",
        \\            .hash = "smart_pointers-0.0.4-abc",
        \\            .lazy = true,
        \\        },
        \\    },
        \\    .paths = .{ "build.zig", "src" },
        \\}
        \\
    );
    defer zon.deinit(t.allocator);

    try t.expectEqual(@as(usize, 2), zon.dependencies.items.len);
    try t.expect(zon.isDependency("zlint"));
    try t.expect(zon.isDependency("smart-pointers"));
    try t.expect(!zon.isDependency("std"));

    try t.expectEqual(@as(usize, 1), zon.path_dependencies.items.len);
    try t.expectEqualStrings("vendor/zlint", zon.path_dependencies.items[0]);
}

test "a manifest without dependencies, or that fails to parse, is empty" {
    var none = try ZonFile.parse(t.allocator, ".{ .name = .demo, .version = \"0.0.0\" }\n");
    defer none.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), none.dependencies.items.len);

    var broken = try ZonFile.parse(t.allocator, ".{ .name = .demo, .dependencies = .{ .x = \n");
    defer broken.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), broken.dependencies.items.len);
}
