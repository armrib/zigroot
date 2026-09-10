# A `return struct {...};` inside a `type`-returning function body strands its fields

```zig
fn FixedList(comptime N: usize) type {
    return struct {
        items: [N]u8 = undefined,
        len: usize = 0,
    };
}

pub fn main() void {
    var x: FixedList(4) = .{};
    x.len = 1;
}
```

`N`, `items`, and `len` are all reported dead even though `FixedList`
is called from `main` and `len` is used. Minimal repro above; found
scanning formic's `iam-verify.zig` SDK, which uses this exact
`fn FixedRoleList(comptime N: usize) type { return struct { items:
[N]RoleEntry = undefined, len: usize = 0, ... }; }` shape — a standard
Zig generic-container idiom.

`SymbolGraph.build` already has a Phase 25 mechanism
(`edgeAnonymousContainerFields` in `src/SymbolGraph.zig`) for exactly
this class of problem — an anonymous `struct {...}` with no container
symbol of its own to hang Phase 21's "container -> its own fields" edge
off of — but it only looks at the function's *signature*:

```zig
if (proto.ast.return_type.unwrap()) |return_type| {
    try edgeAnonymousContainerFields(gpa, &graph, file, semantic, &decl_index, sym_id, return_type);
}
```

That covers `fn foo() struct { x: u8 } { ... }`, where the anonymous
struct is spelled directly in the return-type position. It doesn't
cover a `type`-returning function whose body has a `return
struct {...};` statement — the far more common idiom for a generic
container, since the return type there is just the keyword `type`, and
the actual struct literal only exists inside the body.

Confirmed the field/param themselves resolve fine once reached — it's
specifically that nothing ever edges `FixedList -> items`/`FixedList ->
len`/`FixedList -> N`, so BFS reachability never marks them, even
though `FixedList` itself is definitely called.

Fix sketch: extend (or add a sibling to) `edgeAnonymousContainerFields`
to also scan a `type`-returning function's body for top-level `return
<container-decl>;` statements (a `block`'s direct children, not a
recursive statement walk — matches how `Phase 25`'s doc comment already
scopes "declared inline in a function's return-type or parameter
position") and edge the function to each such returned container's
fields the same way. `x.items`/`x.len` resolving through a *variable*
typed `FixedList(4)` (a call expression, not a plain type name) is a
separate, likely out-of-scope gap per the "no real type inference"
policy — this ticket is only about the function's own reachability
edge to its returned struct's members, which doesn't need any
inference: the struct is spelled out inline in the function that's
already known to be called.
