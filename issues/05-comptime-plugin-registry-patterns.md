# Comptime plugin-registry patterns (struct-field-driven dispatch)

`vendor/zlint`'s lint rules are registered via a config struct's fields
rather than a normal call:

```zig
// linter/config/Rules.zig
duplicate_case: RuleConfig(rules.DuplicateCase) = .{},
```

zigroot's graph has no model for "this struct field's *type* is itself a
live reference to `rules.DuplicateCase`" — so a rule module only ever
reachable this way (never called by name) reads as fully dead, cascading
into everything it calls. `AstComparator.zig`'s only caller,
`duplicate_case.zig`, is unreachable for exactly this reason — 56 dead
lines in one measured run against `vendor/zlint`, and likely more spread
across the other `linter/rules/*.zig` files this pattern also affects.

This is a fundamentally different problem from the `InstanceType`-shaped
gaps (issues 1-3) — there's no call or reference at all, just a type used
as a struct field's type. Needs its own design, not an extension of
`InstanceType`/`FieldChain`.
