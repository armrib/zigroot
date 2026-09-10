//! Global identity of a symbol within a `Project`.
//!
//! ZLint's `Symbol.Id` is only unique within the `Semantic` of the file it
//! came from. `SymbolId` does no remapping — it just pairs that per-file id
//! with the `FileId` of the owning file, giving a value that's unique
//! project-wide and usable as a hash map key (Phase 4's `SymbolGraph`).

const zlint = @import("zlint");
const FileId = @import("FileId.zig").FileId;

pub const SymbolId = struct {
    file: FileId,
    local: zlint.Semantic.Symbol.Id,

    pub fn eql(self: SymbolId, other: SymbolId) bool {
        return self.file == other.file and self.local == other.local;
    }
};
