# A member of an inline `error{...}` return type is reported dead

```zig
pub fn cmp(a: i32, b: i32) error{TypeMismatch}!i32 {
    if (a < 0) return error.TypeMismatch;
    return a - b;
}

pub fn main() !void {
    const r = try cmp(1, 2);
    std.debug.print("{d}\n", .{r});
}
```

Reports `TypeMismatch` dead even though `main` is a root, `cmp` is
reachable from it, and `cmp`'s own body is what produces
`error.TypeMismatch`. Swapping in a *named* error set instead —

```zig
pub const CmpError = error{TypeMismatch};
pub fn cmp(a: i32, b: i32) CmpError!i32 { ... }
```

— reports nothing dead; only the inline/anonymous form is affected.

Found running zigroot against formic's db backend: `src/vm/value.zig`'s
`cmpValue` has `pub fn cmpValue(a: Value, b: Value) error{TypeMismatch}!i32`
with a matching `return error.TypeMismatch;`, `error.Overflow`-shaped
comparisons for `<`/`>` in the same file, etc. — same pattern, real code.

Root cause: `SymbolGraph.anonymousContainer` (`src/SymbolGraph.zig`)
is what lets Phase 25 edge a function to the fields of a `struct`/
`union`/`enum` written inline in its return type or parameters (since
ZLint never gives an anonymous container its own symbol — see the
`SymbolGraph.build` doc comment's Phase 25 section). Its unwrap loop
handles `.error_union` (the `!` in `Err!Payload`) by descending into
`node_and_node[1]`, the *payload* side, to keep looking for a
struct/union/enum there — but it never looks at `node_and_node[0]`,
the error-set side, and its terminal-node switch arm doesn't list
`.error_set_decl` at all. So `error{TypeMismatch}!i32` unwraps straight
past the error set to `i32`, hits `else => return null`, and
`TypeMismatch` never gets an edge from anything.

Unlike a struct/union/enum's fields, though, an error set's members
aren't individual AST nodes — ZLint's `Builder.visitErrorSetDecl`
(`Semantic/Builder.zig`) walks the identifier tokens between `{` and
`}` and calls `declareMemberSymbol` with `.declaration_node = node_id`
(the *whole* `error_set_decl` node) for every member, so all of an
anonymous error set's members share one `decl` node. `SymbolGraph.build`
builds its `decl_index` as a `Node.Index -> Symbol.Id` map via
`putAssumeCapacity`, one entry per symbol — so even if
`anonymousContainer`/`edgeContainerFields` were extended to recognize
`.error_set_decl`, looking a member up by matching `decl_index` against
the container node (the way struct/union/enum fields are found) would
only ever recover one member, silently dropping the others whenever an
anonymous error set has more than one name.

(Named error sets sidestep this: `Builder.visitErrorSetDecl` declares
each member under whatever *named* container is on ZLint's
container-symbol stack, e.g. `CmpError` for `const CmpError =
error{TypeMismatch}`, so Phase 21's ordinary "every container symbol
edges to its own members" (`semantic.symbols.getMembers(sym_id)`)
already covers them — no Phase 25 special-casing needed.)

Fix sketch: teach `anonymousContainer` to also unwrap the error-set
side of an `.error_union` and recognize `.error_set_decl` as a
terminal node, but resolve its members without going through
`decl_index`/`edgeContainerFields`'s node-matching (which assumes one
symbol per node) — e.g. walk the `error_set_decl`'s member identifier
tokens directly and look each one up among the enclosing scope's
member symbols by name, or track a per-container-node counter/list
instead of a single `Node.Index -> Symbol.Id` map.
