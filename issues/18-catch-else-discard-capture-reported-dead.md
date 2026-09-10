# The `_` error-capture in `catch |_|`/`else |_|` is reported dead

```zig
fn mayFail() !void {
    return error.Oops;
}

pub fn main() !void {
    mayFail() catch |_| {};
}
```

Reports one dead declaration named `_` — even though `main` is a root
and the only thing wrapping it (the `catch` clause) is fully reachable.

Found running zigroot against formic's b2c backend (`src/main.zig` has
three of these: two `else |_| {}` and one `} else |_| {}` around
best-effort address-parsing fallbacks) and hap's equivalent. `_` in a
`catch |_|`/`else |_|` capture is Zig's discard binding — referencing
it is not valid Zig syntax, so it can never be "used" by construction,
same category as issue 17's fn-type parameter names. Flagging it dead
is pure noise: every `catch |_|` or `else |_|` in any codebase this
tool runs against will produce one, and there is no way to "fix" it
short of removing error handling.

Root cause: ZLint's `Semantic.Builder` still binds a symbol for a
`_`-named catch/else capture, same as it would for a named one (`catch
|err|`). `Reachability.deadSymbols` (`src/Reachability.zig`) iterates
every non-`s_extern` symbol in `f.semantic.symbols` and reports
whichever aren't reachable — `_` is never referenced (can't be, by
Zig's own rules), so it always lands in the dead set. Unlike issue 17,
there's no enclosing-but-reachable owner subtlety here — the capture
is just a symbol whose name makes it structurally unreferenceable, and
`deadSymbols` doesn't filter on name.

Fix sketch: in `Reachability.deadSymbols`, skip any symbol whose
identifier token is `_`, alongside the existing `s_extern` skip. Worth
checking whether this should also cover other discard-only binding
sites ZLint gives symbols to (e.g. a `_` capture in `if`/`while`/`for`
payloads, if those are ever bound as real symbols rather than treated
like the `s_payload` nodes `OwnerMap.build` already special-cases) —
this repro only confirms the `catch`/`else` capture case.
