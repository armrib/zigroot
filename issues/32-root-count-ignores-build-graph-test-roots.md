# "loaded N files reachable from M roots" ignores build-graph test roots

`main.zig:113-116` prints `opts.roots.items.len` as the root count — the
number of `--root` flags the user passed on the command line. But
`Project.loadBuildGraph` (called just before, at `main.zig:99`) appends
one root per `b.addTest` target it finds in the `--build-zig` graph
(`Project.zig:97-101`), and those roots are what actually pulled in most
of `project.files` by the time this line runs. The printed root count
undercounts whenever `--build-zig` is passed and the build script has
any `addTest` targets — which is the common case.

Measured against `formic/backend`
(`zigroot --root apps/iamd/src/main.zig --dir apps/iamd/src --build-zig build.zig`,
run from `backend/`): prints `loaded 434 file(s) reachable from 1
root(s)`, but only a fraction of those 434 files are reachable from the
one `--root` — most come from `addTest` targets in `staticd`,
`clusterd`, `codegen`, and other apps entirely unrelated to `iamd`,
each contributing its own root. The message reads as if a single
`--root` pulled in the whole 434-file graph, which is misleading when
diagnosing why an unrelated app's files ended up loaded.

Fix sketch: track the project's actual root count (`project.roots.items.len`
after both `loadBuildGraph` and the `--root` loop have run) and print
that instead of `opts.roots.items.len`.
