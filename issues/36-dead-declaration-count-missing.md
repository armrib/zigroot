# Dead-declaration section header has no count, unlike the other two sections

`main.zig`'s three report sections are meant to look alike: a header
line naming how many findings follow, then the findings. Two of the
three do that —

```
741 unresolved import(s):
379 orphan file(s) (unreachable from any root):
```

— but the third doesn't:

```
dead declaration(s) (unreachable from any root):
```

`main.zig:179` and `:191` print the header with a literal
`"dead declaration(s)"` and no `{d}` count, unlike
`main.zig:119`'s `"{d} unresolved import(s):\n"` and `:142`'s
`"{d} orphan file(s)..."`. It's printed lazily, the first time
`reported == 0` inside the streaming loop over `dead.items`, before the
final count is known — that's presumably why it was left out, unlike
the other two sections which iterate a fully-materialized slice first
and can print `items.len` up front.

This isn't just cosmetic on a corpus the size of `formic/backend`: the
dead-declaration section there runs to several thousand lines (measured
via `zigroot --root apps/clusterd/src/main.zig --dir backend --build-zig
build.zig`), and having no count up front — unlike the two sections
above it, which do — makes it much harder to judge scale before scrolling
through the whole list, or to script a threshold check the way the
existing "orphan files found" exit code already allows for that section.

Fix sketch: `reachability.deadSymbols` already returns a materialized
`dead.items` slice before the printing loop runs (`main.zig:160`), same
as `orphans` does for its section — count matches the same way `reported
> 0` is already computed (skip SCC-cycle members and empty-name symbols,
i.e. run the same filter as the print loop once to get a count, or track
it as a first pass), then print `"{d} dead declaration(s)
(unreachable from any root):\n"` with that count instead of the bare
string literal.
