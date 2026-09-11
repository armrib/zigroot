//! Test helpers for the semantic tree's own regression tests. Trimmed from
//! ZLint's `src/Semantic/test/util.zig` (see `../UPSTREAM.md`): the
//! graphical error reporter and `Source` wrapper are gone, diagnostics are
//! printed plainly.
const std = @import("std");

const Semantic = @import("../Semantic.zig");

const t = std.testing;
const print = std.debug.print;

/// Build a Semantic from source, returning the raw Result so tests can
/// inspect errors. Unlike `build`, this does not fail on analysis errors —
/// callers are expected to assert on `result.hasErrors()` themselves.
pub fn buildWithErrors(src: [:0]const u8) !Semantic.Builder.Result {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();
    return try builder.build(src);
}

pub fn build(src: [:0]const u8) !Semantic {
    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();

    var result = builder.build(src) catch |e| {
        print("Analysis failed on source:\n\n{s}\n\n", .{src});
        return e;
    };
    errdefer result.value.deinit();
    if (result.hasErrors()) {
        defer result.deinitErrors();
        print("Analysis failed.\n", .{});
        for (result.errors.items) |err| {
            print("  {s}: {s}\n", .{ err.severity.asSlice(), err.message });
            for (err.labels.items) |label| {
                print("    at bytes {d}..{d}\n", .{ label.span.start, label.span.end });
            }
        }
        print("\nSource:\n\n{s}\n\n", .{src});
        return error.AnalysisFailed;
    }

    result.deinitErrors();
    return result.value;
}
