# Array-index into a cross-file-typed slice field

```zig
// conn.zig
pub const Conn = struct {
    pub fn reset(self: *Conn) void { ... }
};

// state.zig
const conn_mod = @import("conn.zig");
pub const State = struct {
    conns: []conn_mod.Conn,

    pub fn free_conn(self: *State, idx: u16) void {
        self.conns[idx].reset();
    }
};
```

`self.conns[idx].reset()` reports `Conn.reset` dead. In
`FieldChain.resolveChain` (`src/FieldChain.zig`), the array-access
unwrap is gated on `type_resolved != null`:

```zig
if (type_resolved != null) {
    if (arrayAccessNode(ast, current.node)) |access_node| { ... }
}
```

`type_resolved` comes from `InstanceType.resolve`, which is same-file
only. For `conns: []conn_mod.Conn`, the element type crosses an
`@import` boundary, so `resolve` returns `null` (only
`InstanceType.crossFileRoot` can find it) and the array-access branch
is skipped entirely — the walk falls through to `DynamicField.resolve`,
fails, and `break`s with no `.stuck` marker, so `Resolver` never gets a
chance to finish the hop the way it does for the analogous
`fieldAccessName` case just below (which explicitly checks
`InstanceType.crossFileRoot` and returns `.stuck` when `resolve` alone
wasn't enough).

Confirmed with a minimal two-file repro (`conns: []conn_mod.Conn`, one
`self.conns[idx].reset()` call) reachable only from `main`.

Fix sketch: mirror the `fieldAccessName` branch's fallback — when
`arrayAccessNode` finds an array-access hop but `type_resolved` is
`null`, check `InstanceType.crossFileRoot(symbols, owner_map,
current.symbol)` and return a `.stuck` result (analogous to the
existing one) so `Resolver` can finish resolving the slice's cross-file
element type and continue the chain from there.
