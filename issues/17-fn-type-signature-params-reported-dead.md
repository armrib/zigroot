# Parameter names in a bare function-type expression are reported dead

```zig
const Handler = struct {
    on_data: *const fn (ctx: *anyopaque, conn: u32, bytes: []const u8) void,
};

pub fn main() void {
    var h: Handler = undefined;
    _ = &h;
}
```

Reports `ctx`, `conn`, and `bytes` as three separate dead declarations,
even though `Handler` (their only possible "owner") is reachable — `h`'s
type references it from `main`, a root.

Found running zigroot against formic's b2c and hap backends
(`src/loop.zig`'s `Handler`/`AuxHandler` structs, which spell out
callback signatures this way — `on_data: *const fn (ctx: *anyopaque, loop:
*Loop, conn: ConnId, bytes: []const u8) void`) and stress-tested
minimally above: every named parameter of every such field reports dead,
14 findings from one file in the hap backend alone.

Root cause: ZLint's `Semantic.Builder.visitFnProto`
(`Semantic/Builder.zig`) binds a `s_fn_param` symbol for every named
parameter of *any* `fn_proto` node — whether it's a real function
declaration (`fn_proto.name_token != null`, backed by a body) or a bare
function-*type* expression used as a value/field type (`name_token ==
null`, no body, no callable scope). Parameter names in the latter are
pure documentation; there is no scope in which referencing `ctx` or
`conn` would even be syntactically valid, so they can never be "used" by
construction — flagging them dead conveys nothing actionable.

`Reachability.ownerOf` (`src/Reachability.zig`) climbs a fn-param's
owner chain via `OwnerMap`, same as any other symbol. For a real
function's param, the type-expr decl node sits inside the `fn_decl`'s
body/subtree, so `outermostDead` correctly folds an unreferenced real
param under its (usually also-dead) enclosing function. For a bare
fn-type param, the owner chain instead lands on whatever container
symbol the field belongs to (`Handler` here) — and since `Handler` is
independently reachable (used as a type elsewhere), `outermostDead`'s
loop breaks immediately (`!dead_ids.contains(owner)`), leaving the param
reported standalone instead of folded away or suppressed.

Fix sketch: in `Reachability.deadSymbols` (`src/Reachability.zig`),
skip `s_fn_param` symbols whose enclosing `fn_proto` has no body —
i.e. isn't a `fn_decl` — the same way `s_extern` is already skipped
(`if (f.semantic.symbols.get(local).flags.s_extern) continue;`). This
needs a way to tell "named function declaration" from "bare fn-type
expression" from the symbol/AST alone; `zlint`'s `Ast.fullFnProto` plus
checking whether the underlying node is a `fn_decl` (has a body) versus
a bare `fn_proto`/`fn_proto_*` type node should distinguish them.
