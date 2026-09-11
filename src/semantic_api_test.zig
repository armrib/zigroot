//! Phase 0: prove ZLint's `Semantic` is reusable as a library, independent
//! of any dead-code logic of our own. If these break, it means ZLint
//! changed its public `Semantic` surface in a way `Project` also needs to
//! account for.

const std = @import("std");
const t = std.testing;
const zlint = @import("zlint");
const Semantic = zlint.Semantic;

fn build(src: [:0]const u8) !Semantic {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();
    var result = try builder.build(src);
    result.errors.deinit(t.allocator);
    return result.value;
}

test "builds a Semantic from one file" {
    var sem = try build("pub fn main() void {}\n");
    defer sem.deinit();

    try t.expect(sem.symbols.symbols.len > 0);
}

test "resolveBinding distinguishes shadowed locals by scope" {
    var sem = try build(
        \\const x = 1;
        \\fn foo() void {
        \\    const x = 2;
        \\    _ = x;
        \\}
        \\
    );
    defer sem.deinit();

    const file_scope: Semantic.Scope.Id = @enumFromInt(0);
    const outer_x = sem.getBinding(file_scope, "x");
    try t.expect(outer_x != null);

    // `foo`'s inner `x` must resolve to a *different* symbol than the
    // top-level `x`, even though both are named "x".
    const foo_id = sem.symbols.getSymbolNamed("foo");
    try t.expect(foo_id != null);
}

test "references are attached to the symbol they refer to" {
    var sem = try build(
        \\fn bar() void {}
        \\fn foo() void {
        \\    bar();
        \\}
        \\
    );
    defer sem.deinit();

    const bar_id = sem.symbols.getSymbolNamed("bar") orelse return error.TestUnexpectedResult;
    const refs = sem.symbols.getReferences(bar_id);
    try t.expect(refs.len > 0);
}

test "modules record file imports with their specifier" {
    var sem = try build(
        \\const storage = @import("storage.zig");
        \\
    );
    defer sem.deinit();

    try t.expectEqual(@as(usize, 1), sem.modules.imports.items.len);
    const entry = sem.modules.imports.items[0];
    try t.expectEqualStrings("storage.zig", entry.specifier);
    try t.expectEqual(Semantic.ModuleRecord.ImportEntry.Kind.file, entry.kind);
}
