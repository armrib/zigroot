# `anytype` parameter not rolled up into its dead parent

```zig
pub fn call_cb(cb: anytype) void {
    cb(1);
}
```

Both `call_cb` and `cb` are reported as separate top-level dead
declarations instead of `call_cb (+1 nested)` — every other kind of
dead parameter/local correctly folds into its parent (per
`Reachability.deadSymbols`'s rollup, `src/Reachability.zig`).

Root cause: an `anytype` parameter has no type-expression node of its
own, so ZLint declares it at the *same* AST node as its enclosing
`fn_decl` (`OwnerMap.build`'s comment on `s_fn_param` explains this).
`OwnerMap.build`'s `decl_of` map is keyed by node, so it registers only
the function symbol at that shared node (the `if
(sym.flags.s_fn_param and decl_of.contains(decl)) continue;` guard
skips registering the parameter). `Reachability.ownerOf` then computes
`cb`'s owner as `owner_map.get(cb.decl)` — but `cb.decl` *is* that
shared `fn_decl` node, and `OwnerMap.build`'s node-owner walk climbs
from `getParent(node)`, never checking the node against `decl_of`
itself — so it returns `call_cb`'s *own* owner (its enclosing
container/file root) rather than `call_cb`. `cb` ends up attributed to
the wrong, non-dead container instead of its actually-dead function.

Fix sketch: `Reachability.ownerOf` (or `OwnerMap`) needs a special case
for an `anytype` parameter sharing its function's decl node — its owner
is that function symbol itself, not whatever `owner_map.get` resolves
the shared node to.
