//! Trimmed copy of ZLint's `src/util.zig`: only what the semantic tree
//! references. See `UPSTREAM.md`.
const std = @import("std");
const builtin = @import("builtin");
pub const RUNTIME_SAFETY = builtin.mode != .ReleaseFast;
pub const IS_DEBUG = builtin.mode == .Debug;
pub const IS_TEST = builtin.is_test;

pub const @"inline": std.builtin.CallingConvention = if (IS_DEBUG) .@"inline" else .auto;

pub const NominalId = @import("util/id.zig").NominalId;
pub const Bitflags = @import("util/bitflags.zig").Bitflags;

/// Assert that `condition` is true, panicking if it is not.
///
/// Behaves identically to `std.debug.assert`, except that assertions will fail
/// with a formatted message in debug builds. `fmt` and `args` follow the same
/// formatting conventions as `std.debug.print` and `std.debug.panic`.
///
/// Similarly to `std.debug.assert`, undefined behavior is invoked if
/// `condition` is false. In `ReleaseFast` mode, `unreachable` is stripped and
/// assumed to be true by the compiler, which will lead to strange program
/// behavior.
pub inline fn assert(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) std.debug.panic(fmt, args);
    } else {
        if (!condition) unreachable;
    }
}

/// Assert that `condition` is true, panicking in debug builds if it is not.
/// Unlike `assert`, `debugAssert` will not trigger undefined behavior for
/// `false` conditions in release builds.
pub inline fn debugAssert(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!condition) {
        @branchHint(.cold); // panic sets .cold, but that's lost in release builds.
        if (comptime IS_DEBUG) std.debug.panic(fmt, args);
    }
}

pub inline fn assertUnsafe(condition: bool) void {
    if (comptime IS_DEBUG) {
        if (!condition) @panic("assertion failed");
    } else {
        @setRuntimeSafety(IS_DEBUG);
        if (!condition) unreachable;
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
