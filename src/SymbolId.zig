//! Global identity of a symbol within a `Project`.
//!
//! ZLint's `Symbol.Id` is only unique within the `Semantic` of the file it
//! came from. `SymbolId` does no remapping — it just pairs that per-file id
//! with the `FileId` of the owning file, giving a value that's unique
//! project-wide and usable as a hash map key (Phase 4's `SymbolGraph`).

const std = @import("std");
const Semantic = @import("semantic/Semantic.zig");
const FileId = @import("FileId.zig").FileId;

pub const SymbolId = struct {
    file: FileId,
    local: Semantic.Symbol.Id,

    /// Same as `std.meta.eql`; kept as a method so call sites read as
    /// `a.eql(b)` next to the ZLint id types' own `eql`s.
    pub fn eql(self: SymbolId, other: SymbolId) bool {
        return std.meta.eql(self, other);
    }
};
