# A method called through a field-access-initialized variable is reported dead

```zig
const Server = struct {
    pub fn drive(self: *Server) void {
        ...
    }
};

const ReqCtx = struct {
    srv: *Server,

    pub fn finish(self: *ReqCtx) void {
        const srv = self.srv;
        srv.drive();
    }
};
```

Reports `drive` dead even though `finish` is reachable and its body calls
it. Rewriting the last two lines as `self.srv.drive();` — no intermediate
variable — makes `drive` resolve and report nothing dead; only the
extra-local-variable form is affected.

Found running zigroot against formic's b2c and hap backends: both
`server.zig` files (hap's header comment says the code is duplicated
from b2c) have `ReqCtx.finish` methods shaped exactly like this —
`const srv = self.srv;` followed by `srv.drive(...)`, `srv.sendLarge(...)`,
etc. — real code, not synthetic.

Root cause: `InstanceType.declaredTypeNodes` (`src/InstanceType.zig`) is
what resolves a variable's syntactic type so `srv.drive()` can chain to
`Server`'s exports the same way `self.srv.drive()` does. For an
`s_variable` symbol it only looks at two candidates: the var decl's own
explicit type annotation (`const srv: Server = ...`) and an
explicitly-typed struct-literal initializer's type expr (`const srv =
Server{...}`). It never looks at a plain field-access initializer
(`const srv = self.srv;`) at all — so `srv` falls straight through to
`resolve`'s `declaredTypeNodes` loop finding nothing, `resolveTypeExpr`
is never called, and `srv.drive()` never gets to `FieldChain.findExport`.

This is unlike the `db.zig`-shaped case `InstanceType`'s own doc comment
already excludes (`inflight.cont.call(...)` where `inflight` comes from
`hashmap.fetchRemove(...).value`, a call return) — here both hops are
100% syntactic: `self`'s type is `finish`'s own `self: *ReqCtx` param
annotation (Phase 18), and `srv`'s type is `ReqCtx.srv`'s own field
annotation (Phase 22, `foo: Foo` inside a struct). Nothing needs to be
inferred from a call return; the existing per-hop machinery just isn't
being invoked for this init-node shape.

Fix sketch: `optionalPayloadSource` in the same file already solves the
analogous problem for `if (self.field) |x| ...` — it walks the payload's
condition expression's base identifier through `FieldChain.resolveChain`
to find the field/variable whose own declared type is what's being
unwrapped. `declaredTypeNodes`'s variable branch could do the same for a
plain (non-struct-literal) `init_node`: if it's an identifier or
same-file `.field` chain (not a call, not a literal), walk it through
`FieldChain.resolveChain`/`resolve` recursively to find the source
symbol's declared type, instead of only checking `type_node` and a
struct-literal's `type_expr`.
