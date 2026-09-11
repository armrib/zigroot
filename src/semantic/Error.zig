//! An error reported during parsing or semantic analysis.
//!
//! Trimmed copy of ZLint's `src/Error.zig` (see `UPSTREAM.md`): the
//! clone-on-write message, `Arc`-shared source text, JSON serialization and
//! severity parsing that ZLint's reporter needed are gone. What's left is
//! what `Builder` produces and what a caller needs to print a diagnostic:
//! a message, an optional code, and byte-offset labels into the source the
//! `Semantic` was built from (the caller already holds that source).
//!
//! Errors are most commonly managed by a `Result`. In this form, the
//! `Result` holds ownership over allocations.

code: []const u8 = "",
/// Owned iff `message_owned`.
message: []const u8,
message_owned: bool = false,
severity: Severity = .err,
/// Text ranges over problematic parts of the source code.
labels: std.ArrayListUnmanaged(LabeledSpan) = .empty,
/// Name of the file being analyzed. Owned.
source_name: ?[]const u8 = null,
/// Optional static help text.
help: ?[]const u8 = null,

/// Takes ownership of `message`, which must have been allocated with
/// `allocator` (the same allocator later passed to `deinit`).
pub fn new(message: []u8, allocator: Allocator) Error {
    _ = allocator;
    return Error{ .message = message, .message_owned = true };
}

pub fn newStatic(comptime message: []const u8) Error {
    return Error{ .message = message };
}

pub fn fmt(alloc: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!Error {
    return Error{ .message = try std.fmt.allocPrint(alloc, format, args), .message_owned = true };
}

pub fn deinit(self: *Error, alloc: std.mem.Allocator) void {
    if (self.message_owned) alloc.free(self.message);
    if (self.source_name) |src_name| alloc.free(src_name);
    self.labels.deinit(alloc);
    self.* = undefined;
}

/// Severity level of a diagnostic.
pub const Severity = enum {
    err,
    warning,
    notice,
    off,

    pub fn asSlice(self: Severity) []const u8 {
        switch (self) {
            .err => return "error",
            .warning => return "warn",
            .notice => return "notice",
            .off => return "off",
        }
    }
};

/// Results hold a value and a list of errors. Useful for error-recoverable
/// situations, where a value may still be produced even if errors are
/// encountered.
///
/// All errors in a `Result` must be allocated with the same allocator, which
/// must be `Result.alloc`.
pub fn Result(comptime T: type) type {
    const ErrorList = std.ArrayListUnmanaged(Error);
    return struct {
        value: T,
        errors: ErrorList = .empty,
        alloc: Allocator,

        const Self = @This();

        /// Create a new `Result`. No memory is allocated.
        pub fn new(alloc: Allocator, value: T, errors: ErrorList) Self {
            return .{
                .value = value,
                .errors = errors,
                .alloc = alloc,
            };
        }

        /// Create a successful `Result` instance. No memory is allocated.
        pub fn fromValue(alloc: std.mem.Allocator, value: T) Self {
            return .{
                .value = value,
                .alloc = alloc,
            };
        }

        /// Free both the success value and the error list. The result is no
        /// longer usable after calls to this method.
        pub fn deinit(self: *Self) void {
            self.value.deinit();
            self.deinitErrors();
        }

        /// Free the error list, leaving `value` untouched. Caller must ensure
        /// that `value` gets de-alloc'd later. Following calls to
        /// `Result.deinit` will result in a double-free.
        pub fn deinitErrors(self: *Self) void {
            for (self.errors.items) |*err| err.deinit(self.alloc);
            self.errors.deinit(self.alloc);
        }

        pub fn hasErrors(self: *const Self) bool {
            return self.errors.items.len != 0;
        }
    };
}

const Error = @This();

const std = @import("std");
const _span = @import("span.zig");

const Allocator = std.mem.Allocator;

pub const Span = _span.Span;
pub const LabeledSpan = _span.LabeledSpan;

test "Error.fmt owns its message" {
    var err = try Error.fmt(std.testing.allocator, "bad {s}", .{"thing"});
    defer err.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bad thing", err.message);
    try std.testing.expect(err.message_owned);
}
