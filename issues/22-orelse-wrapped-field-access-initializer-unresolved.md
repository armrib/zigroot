# A method called through an `orelse`-wrapped field-access-initialized variable is reported dead

```zig
const Server = struct {
    pub fn drive(self: *Server) void {
        ...
    }
};

const AppCtx = struct {
    srv: ?*Server = null,
};

fn finish(ctx: *AppCtx) void {
    const srv = ctx.srv orelse return;
    srv.drive();
}
```

Reports `drive` dead even though `finish` is reachable and its body calls
it. Dropping the `orelse return` (making `srv` non-optional and the
initializer a bare `ctx.srv`) makes `drive` resolve and report nothing
dead; only the `orelse`-wrapped form is affected.

Found running zigroot against formic's `drive` backend: `AppCtx.byte_store`
is `?Storage`, and every handler that touches the byte store starts with
`const bs = app.byte_store orelse return res.err(...);` before calling
`bs.writeStaging(...)`, `bs.readBlob(...)`, etc. — real code, not
synthetic. Because `bs`'s type never resolves, none of `Storage`'s
interface methods (nor the `FilesystemStore`/`MemoryStore` impls reached
only through them) are ever marked reachable — one unresolved init-node
shape cascades into dozens of false-positive dead declarations across
`store/byte_store.zig`.

Root cause: `InstanceType.fieldAccessInitSource` (`src/InstanceType.zig`)
requires `decl.ast.init_node` to be a bare `.identifier` or `.field_access`
node (`switch (ast.nodeTag(init_node)) { .identifier, .field_access => {},
else => return null }`). An `orelse`/`catch`-wrapped initializer
(`ctx.srv orelse return`) has node tag `.@"orelse"`, so it falls straight
to `else => return null` and `srv` never gets a resolved type.

This is exactly the unwrap `InstanceType.callInit` already does for the
analogous call-init case (same file, ~line 519): `switch (ast.nodeTag
(init_node)) { .@"catch", .@"orelse" => init_node = ast.nodeData
(init_node).node_and_node[0], else => {} }` before looking for a call
expression, so `Foo.find(id) orelse return` resolves the same way
`Foo.find(id)` alone would.

Fix sketch: `fieldAccessInitSource` should unwrap `.@"catch"`/`.@"orelse"`
the same way before its `.identifier`/`.field_access` switch — pulling the
left operand (`node_and_node[0]`) out of the `catch`/`orelse` node first,
then proceeding with the existing base-identifier walk through
`FieldChain.resolveChain` unchanged.
