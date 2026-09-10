# `Roots.importTarget`'s unconditional per-symbol linear scan is quadratic in project size

`zigroot` takes over 90 seconds on formic's `iamd` backend — a project of
a similar file-count order to several other formic backends that each
finish in 1-2 seconds:

```
$ time zigroot --root backend/apps/iamd/src/main.zig --dir backend --build-zig backend/build.zig
real    1m32.7s

$ time zigroot --root backend/apps/staticd/src/main.zig --dir backend --build-zig backend/build.zig
real    0m1.7s
```

`iamd`'s import graph reaches more of `backend` (its dead-symbol report is
~9x longer than `staticd`'s), but the runtime is ~53x longer — clearly
super-linear.

`perf record` on the `iamd` run shows `Roots.importTarget` alone
accounting for 20% of total self time (`Roots.build`/`buildInstanceTypes`-
adjacent work accounts for most of the rest):

```
20.01%    20.01%  zigroot  zigroot  [.] Roots.importTarget
```

Root cause: `Roots.build`'s main loop (`src/Roots.zig:101-192`) iterates
every symbol of every file in the project, and for *each* symbol,
unconditionally calls `importTarget(project, f.id, sym_id)`
(`src/Roots.zig:121`) before even checking whether the symbol has any
`test`-block references — the only place `import_target`'s result is
actually used (`src/Roots.zig:166`, inside the `test`-scope reference
branch). `importTarget` itself (`src/Roots.zig:223-230`) is a linear scan
over `project.import_graph.edges.items` — every `@import` edge in the
*whole project*, not just `file_id`'s own imports:

```zig
fn importTarget(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?FileId {
    for (project.import_graph.edges.items) |edge| {
        if (edge.from != file_id) continue;
        const binding = project.file(edge.from).owner_map.get(edge.node) orelse continue;
        if (binding == base) return edge.to;
    }
    return null;
}
```

So the cost is O(total symbols in project × total import edges in
project), evaluated for every project regardless of whether any symbol
ever turns out to have a `test`-block reference to it. `Resolver.zig` has
the identical pattern in its own `importEdge` (`src/Resolver.zig:236-243`,
used by `importTargetRoot`) — its doc comment says it "mirrors
`Resolver.importTarget`" — but those call sites are gated behind
`InstanceType.crossFileRoot` / an existing `@import` edge match first,
so they don't fire unconditionally per symbol the way `Roots.zig:121`
does.

Fix sketch: reorder `Roots.build`'s loop so `importTarget` (and the other
three per-symbol resolutions computed unconditionally alongside it —
`InstanceType.resolve`, `crossInstanceType`, `Resolver.callInstanceType`,
all at `src/Roots.zig:117-121`) are computed lazily, only once a
`test`-scope reference to the symbol is actually found inside the
`ref_it` loop — the `chain`/`inst_chain`/`cross`/`call_instance` branches
already do their real work conditionally, so this only means moving four
lines from before the `ref_it` loop to inside its `isInTestScope` branch.
Separately, `importTarget`/`importEdge`'s per-file linear scan over *all*
project import edges should be an index (e.g. `project.import_graph`
grouping edges by `from: FileId`, or a `(FileId, Symbol.Id) -> FileId`
map built once) rather than a full-project scan repeated per lookup.

Measured impact: `zigroot --root backend/apps/iamd/src/main.zig --dir
backend --build-zig backend/build.zig` against formic's backend takes
~93s wall time (vs. 1-2s for comparably-sized formic backends), of which
`Roots.importTarget` alone is 20% of total CPU self time per `perf record`.
