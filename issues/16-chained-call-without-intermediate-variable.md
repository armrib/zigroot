# A method call chained directly off a call expression isn't resolved

```zig
pub const Storage = struct {
    put_fn: *const fn () void,
};

pub const HttpClient = struct {
    pub fn storage(self: *HttpClient) Storage {
        const vt = struct {
            fn put(raw: *anyopaque) void {
                cast(raw).putImpl(); // no intermediate variable
            }
            fn cast(raw: *anyopaque) *HttpClient {
                return @ptrCast(@alignCast(raw));
            }
        };
        return .{ .put_fn = vt.put };
    }

    fn putImpl(self: *HttpClient) void {
        _ = self;
    }
};
```

`putImpl` reports dead even though `put` (reachable via `storage`'s
`.put_fn = vt.put` field-init chain, already handled) calls it through
`cast(raw).putImpl()`. Found running zigroot against a real corpus
(formic's mail backend, `src/ipfs/ipfs.zig`'s `HttpClient.storage()`,
which wires a `Storage.VTable` to five `castImpl`-style methods —
`putImpl`, `getImpl`, `pinImpl`, `unpinImpl`, `hasImpl`, plus
`pinCall` — the same idiom): all six report dead, stranding the
entire real (non-`MemoryStore`) IPFS backend. Minimally reproduced
with the shape above.

Every existing call-init mechanism — `InstanceType.callInit` /
`Resolver.callInstanceType` (`var s = Foo.init(...); s.run();`) —
requires a **variable declaration** to hang the resolved type on:
`callInit` reads `symbol.flags.s_variable` and `fullVarDecl` off the
`sym_id` it's given, then `buildCallInstanceTypes`
(`src/Resolver.zig`) iterates *references to that variable* to add
chain edges. `cast(raw).putImpl()` never assigns `cast(raw)` to a
variable — `.putImpl` hops directly off the call expression's result.

Root cause is upstream of that, in `FieldChain.resolveChain`
(`src/FieldChain.zig`): `SymbolGraph.build` calls it starting from
`sym_id = cast`'s own symbol (the reference at the `cast` identifier
in `cast(raw)`) and `start_node` = that identifier's node. The first
thing `resolveChain` does is `fieldAccessName(ast, current.node)`,
which checks whether `current.node`'s *immediate* parent is a
`field_access` — but `cast`'s immediate parent is the `call` node
`cast(raw)`; the `field_access` (`cast(raw).putImpl`) is the call
node's parent, one level further up. `fieldAccessName` returns `null`
on the first check, so the chain never advances past the direct edge
to `cast` itself — `cast` is correctly reachable (`put -> cast`), but
nothing walks from there into `cast`'s *return type* to find
`putImpl`.

This is likely to hit any vtable/duck-typed-interface wiring that
casts an opaque pointer back to a concrete type and immediately calls
through it — a common pattern for `anyopaque`-based interfaces (the
`Storage.VTable` shape here mirrors ZLint's own `LintRule` vtable).

Fix sketch: generalize the existing call-init machinery
(`InstanceType.callInit` / `Resolver.buildCallInstanceTypes`) from
"variable symbol whose initializer is a call" to "call node used
directly as a field-access base," keyed by the call node itself
rather than a variable symbol. Concretely: when `SymbolGraph.build`
(or a new pass alongside `buildCallInstanceTypes`) finds a reference
node whose parent is a `call` and whose grandparent is a
`field_access` with the call as its base, resolve the callee the same
way `callInstanceType` resolves `fn_expr` today (`resolveValueChain`
on the call's callee expression, then that function's own declared
return type, unwrapping `!`/`?`/one leading pointer), and continue
`FieldChain.resolveChain` from that return type instead of stopping.
The same-file case (`SymbolGraph`) and cross-file case (`Resolver`)
both need this, mirroring how `InstanceType`/`Resolver.
callInstanceType` are already split.
