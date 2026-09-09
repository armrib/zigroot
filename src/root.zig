//! zigroot: a whole-project reachability analyzer built above ZLint's
//! single-file `Semantic` layer. See docs/architecture.md for the design.

pub const zlint = @import("zlint");

pub const FileId = @import("project/FileId.zig").FileId;
pub const File = @import("project/File.zig");
pub const ImportGraph = @import("project/ImportGraph.zig");
pub const Project = @import("Project.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("semantic_reuse_test.zig");
    _ = @import("Project_test.zig");
}
