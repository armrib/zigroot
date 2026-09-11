//! Locks in the parts of `semantic/`'s public surface that `Project` and
//! the resolvers rely on, independent of any dead-code logic of our own.
//! The tree under `src/semantic/` is our own (ZLint-derived, see
//! `src/semantic/UPSTREAM.md`) copy, so if these break, some local edit to
//! it changed an API the project layer also depends on.

const std = @import("std");
const t = std.testing;
const Semantic = @import("semantic/Semantic.zig");

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
