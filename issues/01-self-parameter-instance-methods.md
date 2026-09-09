# Instance-method calls on `self`-typed function parameters

**The biggest open gap.** `InstanceType` resolves a variable's declared
type (`var s: Foo = ...`) but has no notion of a function *parameter*'s
declared type. Every method written the idiomatic way —

```zig
fn visitNode(self: *SemanticBuilder, node_id: NodeIndex) !void {
    try self.visit(...);
}
```

— never makes `self.visit`, `self.visitOptional`, etc. reachable, even
once `visitNode` itself is. This is arguably a more common shape than the
locally-declared-variable case `InstanceType` already handles, since
`self`/receiver-style parameters are pervasive in idiomatic Zig.

Confirmed in isolation: a synthetic `self.helper()` call inside a method
stays "dead" even when the method itself is reached from a root.

## Measured impact

Run: `zigroot --root vendor/zlint/src/main.zig --root
vendor/zlint/src/root.zig --dir vendor/zlint/src --build-zig
vendor/zlint/build.zig --library` against `vendor/zlint` (~86 files).

Accounts for the bulk of `Semantic/Builder.zig`'s 194 dead-declaration
lines (`visit`, `visitOptional`, `visitNode`, and dozens of their
locals) — fixing this is the highest-value next step.

## Likely shape of the fix

Extend `InstanceType.resolve` (or a sibling) to read a symbol's type off
its *parameter* declaration (`fullFnProto`'s param list) the same way it
reads a `var`'s type annotation today, then wire it into the same three
call sites `InstanceType` already feeds (`SymbolGraph`, `Resolver`,
`Roots`' `.test`-root case).
