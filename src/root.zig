//! zigroot: a whole-project reachability analyzer built above ZLint's
//! single-file `Semantic` layer. See docs/architecture.md for the design.

pub const Semantic = @import("semantic/Semantic.zig");

pub const FileId = @import("FileId.zig").FileId;
pub const File = @import("File.zig");
pub const ImportGraph = @import("ImportGraph.zig");
pub const OwnerMap = @import("OwnerMap.zig");
pub const SymbolGraph = @import("SymbolGraph.zig");
pub const SymbolId = @import("SymbolId.zig").SymbolId;
pub const Roots = @import("Roots.zig");
pub const Reachability = @import("Reachability.zig");
pub const Resolver = @import("Resolver.zig");
pub const DynamicField = @import("DynamicField.zig");
pub const InstanceType = @import("InstanceType.zig");
pub const Scc = @import("Scc.zig");
pub const BuildGraph = @import("BuildGraph.zig");
pub const Project = @import("Project.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("semantic/Semantic.zig");
    _ = @import("semantic_api_test.zig");
    _ = @import("Project_test.zig");
    _ = @import("OwnerMap_test.zig");
    _ = @import("SymbolGraph_test.zig");
    _ = @import("Roots_test.zig");
    _ = @import("Reachability_test.zig");
    _ = @import("Resolver_test.zig");
    _ = @import("DynamicField_test.zig");
    _ = @import("InstanceType_test.zig");
    _ = @import("Scc_test.zig");
    _ = @import("BuildGraph_test.zig");
}
