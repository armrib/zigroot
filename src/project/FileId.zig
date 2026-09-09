//! Identity of one source file within a `Project`. Indexes into
//! `Project.files`.

pub const FileId = enum(u32) {
    _,

    pub fn index(self: FileId) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) FileId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
};
