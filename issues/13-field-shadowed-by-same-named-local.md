# A field access resolves to a same-named local variable elsewhere in the container

```zig
// conn.zig
pub const Conn = struct {
    in_use: bool = false,
    pub fn reset(self: *Conn) void { self.in_use = false; }
};

// state.zig
const conn_mod = @import("conn.zig");
pub const POOL_SIZE: usize = 256;

pub const State = struct {
    conns: []conn_mod.Conn,

    pub fn init(allocator: std.mem.Allocator) !State {
        const conns = try allocator.alloc(conn_mod.Conn, POOL_SIZE); // local named "conns"
        for (conns) |*c| c.* = .{};
        return .{ .conns = conns };
    }

    pub fn free_conn(self: *State, idx: u16) void {
        self.conns[idx].reset();
    }
};
```

`self.conns[idx].reset()` reports `Conn.reset` dead, even though
`free_conn` (and an `alloc_conn` using a `for (self.conns) |*c|` loop)
are both reachable and definitely call it. Found running zigroot
against a real corpus (formic's chat backend, `state.zig`/`conn.zig`);
minimally reproduced with the shape above.

Root cause is in `FieldChain.findExport` (`src/FieldChain.zig`):

```zig
pub fn findExport(symbols: *const Semantic, owner_map: *const OwnerMap, container: Semantic.Symbol.Id, name: []const u8) ?Semantic.Symbol.Id {
    const resolved = thisAliasRoot(symbols, owner_map, container) orelse container;
    for (symbols.symbols.getExports(resolved).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name)) return id;
    }
    for (symbols.symbols.getMembers(resolved).items) |id| {
        if (std.mem.eql(u8, symbols.symbols.get(id).name, name)) return id;
    }
    return null;
}
```

ZLint's `Symbol.exports` for a container isn't limited to the
container's own top-level `const`/`fn` declarations — it also picks up
`const`/`var` locals declared inside the container's *method bodies*
(confirmed with a scratch test: a `const foo = ...;` inside `State.init`
shows up in `State`'s own `getExports(...)`, regardless of what it's
named). When a method-local happens to share a name with a real field
(`conns` the field vs. `conns` the local in `init`), `findExport`
checks `exports` first and returns on the first name match — so it
returns the untyped local (whose own initializer,
`allocator.alloc(...)`, isn't something `InstanceType` can resolve a
type from) instead of ever reaching `members`, where the real,
correctly `[]conn_mod.Conn`-typed field lives. The chain dead-ends
there, so nothing downstream of `.conns` — including `.reset()` two
hops later — ever gets an edge.

This is likely to hit any container whose method reuses a field's name
for a local (a common pattern: `init` building up the value that then
gets assigned to the field of the same name), silently stranding
everything reachable only through that field as dead.

Fix sketch: `findExport` needs to reject an `exports` candidate that
isn't actually a direct child of `container` — e.g. via `owner_map.get`
on the candidate's own `decl` node, requiring it resolve back to
`resolved` itself (mirroring how `Reachability.ownerOf` already asks
"whose declaration contains this symbol" for the rollup check). A
method-local's owner is the method, not the struct, so it'd correctly
fail that check and fall through past it to the real field in
`members` — or, if the local shares a name with nothing real, `null`
as before.
