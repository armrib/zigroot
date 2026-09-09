# Generic-type-returning function aliases

```zig
const LintWalker = walk.Walker(LintVisitor);
var walker = try LintWalker.init(alloc, src, &visitor);
```

`walk.Walker(LintVisitor)` is a call to a function that returns a *type*
(comptime), aliased to a local const, then instantiated. Different from
the "function-call return value" case (that's about a *value*'s type;
this is about a generic instantiation's result being a type in its own
right) — 29 dead lines in `visit/walk.zig` in one measured run against
`vendor/zlint`.
