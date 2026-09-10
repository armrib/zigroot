# `BuildGraph.parseInto` doesn't recognize `addAnonymousImport`

The `build.zig` scan loop (`BuildGraph.zig:186`) only fires on a method
call literally named `addImport` — `if (!std.mem.eql(u8, field, "addImport")) continue;`
— then resolves its second argument through `bindings` (a previously
recorded `createModule` variable). `Module.addAnonymousImport(name,
options)` is a different, common std API: it creates the module inline
from `options` (an anonymous `.{ .root_source_file = b.path(...), ... }`
struct literal) in the same call, with no separate `createModule`
binding to look up. The scan skips these calls entirely, so any name
bound this way never enters `result.modules` and stays unresolved.

Measured against `formic/backend`
(`zigroot --root apps/cluster-cli/src/main.zig --dir apps/cluster-cli/src --build-zig build.zig`,
run from `backend/`): `build.zig:131` has
```zig
staticd_bench_mod.addAnonymousImport("bench.zig", .{ .root_source_file = b.path("apps/site-build/src/bench.zig") });
```
so `apps/staticd/src/tests/test_bench.zig`'s `@import("bench.zig")`
should resolve to `apps/site-build/src/bench.zig`. Instead it's reported
as an unresolved `[file]` import — the `.file`-kind sibling-relative
fallback also fails since no `bench.zig` sits next to `test_bench.zig`
on disk, so there's no accidental resolution masking the gap.

Fix sketch: in the same loop, branch on `addAnonymousImport` alongside
`addImport`: read the name from `params[0]` as usual, but resolve
`params[1]` as an inline options struct instead of a `bindings` lookup —
`tree.fullStructInit` on it, pull `.root_source_file`'s `b.path(...)`
argument the same way `createModule`'s own field scan already does
elsewhere in this file (`root_source_file` extraction is presumably
factored out already for the `createModule` case; reuse it here on the
literal instead of on a `createModule` call's field list).
