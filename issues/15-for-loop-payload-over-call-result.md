# A for-loop payload over a call-result variable doesn't inherit the callee's return type

```zig
// entry.zig
pub const Entry = struct {
    v: u32 = 0,
    pub fn payload(self: *const Entry) u32 { return self.v; }
};

// main.zig
const entry_mod = @import("entry.zig");

fn tailOf(buf: []entry_mod.Entry, n: usize) []entry_mod.Entry {
    return buf[0..n];
}

pub fn main() void {
    var buf: [4]entry_mod.Entry = undefined;
    const tail = tailOf(buf[0..], 2);
    for (tail) |*e| {
        _ = e.payload();
    }
}
```

`Entry.payload` reports dead even though it's called through `e`, a
`for (tail) |*e|` payload whose element type is `entry_mod.Entry` —
`tailOf`'s return type says so right in its signature. Found in
formic's chat backend: `msg_log.zig`'s `const tail =
self.ring.tail(limit, &tmp); for (tail) |*e| { ...; .payload =
e.payload() };` reports `ring_buf.zig`'s `Entry.payload` dead the same
way.

`InstanceType.forElementSource` (`src/InstanceType.zig`) resolves a
`for (seq) |x|` payload's element type by finding the symbol `seq`
resolves to and recursing into *that symbol's own declared type*. That
recursion works when `seq` is a field or a variable with an explicit
type annotation (`resolveTypeExpr` has a type-expression node to read),
and — since the "call-return-type instance chain" fix (issue 10's
close, commit `5d68cdc`) — when `seq` is itself a plain instance
variable initialized straight from a call whose return type is
statically written. But `forElementSource` only calls
`FieldChain.resolveChain` on `seq`'s own reference node, which just
walks `.field`/`[]` hops *forward* from that node — it never reaches
the call-return-type path that direct instance-variable resolution
gets, so a `for`-loop over a plain `const x = someFn();` (no further
field chain, no type annotation) comes back empty-handed.

Fix sketch: give `forElementSource` the same fallback `resolve`/
`crossFileRoot`'s own variable-handling already has for a call-init
initializer — when `FieldChain.resolveChain` on the bare `seq` symbol
doesn't move past `seq` itself, try resolving `seq`'s declared type the
way a plain instance variable would (the same helper the call-init
instance-chaining fix added), rather than only trying the forward-chain
walk.
