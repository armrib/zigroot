# Nested `const Self = @This();` alias resolution

`FieldChain.findExport` now unwraps a top-level `const X = @This();`
alias to the file's root symbol (fixed in the session that produced this
list — it was silently breaking every container lookup that landed on
such an alias, not just a new code path). That fix is deliberately
scoped to the *file-top-level* case only, checked via "is this symbol one
of `FILE_ROOT_SYMBOL`'s own exports" — cheap, but blind to a `const Self
= @This();` declared inside a *nested* struct, which still won't
resolve.

## Likely shape of the fix

Needs `OwnerMap` (to find the true enclosing container, not just the
file root), which `FieldChain` doesn't currently depend on — either
thread it in, or move this specific case to a caller that already has it
(`Resolver`/`Roots`).
