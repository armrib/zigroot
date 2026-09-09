//! zigroot: a whole-project reachability analyzer built above ZLint's
//! single-file `Semantic` layer. See docs/architecture.md for the design.

pub const zlint = @import("zlint");

pub const FileId = @import("project/FileId.zig").FileId;
pub const File = @import("project/File.zig");
pub const ImportGraph = @import("project/ImportGraph.zig");
pub const OwnerMap = @import("project/OwnerMap.zig");
pub const SymbolGraph = @import("project/SymbolGraph.zig");
pub const SymbolId = @import("project/SymbolId.zig").SymbolId;
pub const Roots = @import("project/Roots.zig");
pub const Reachability = @import("project/Reachability.zig");
pub const Resolver = @import("project/Resolver.zig");
pub const Project = @import("Project.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("semantic_reuse_test.zig");
    _ = @import("Project_test.zig");
    _ = @import("project/OwnerMap_test.zig");
    _ = @import("project/SymbolGraph_test.zig");
    _ = @import("project/Roots_test.zig");
    _ = @import("project/Reachability_test.zig");
    _ = @import("project/Resolver_test.zig");
}
