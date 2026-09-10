# `discoverZigFiles`'s `skip_dirs` misses `.zig-cache`, the actual default cache dir name

`Project.discoverZigFiles`'s `skip_dirs` list is
`{ ".git", "zig-cache", "zig-out", "vendor" }` — but Zig's build system
has named its cache directory `.zig-cache` (leading dot) by default
since 0.12; `zig-cache` (no dot) was the pre-0.12 name. Since the
component comparison is exact-match per path segment, `.zig-cache`
never matches the `"zig-cache"` skip entry, so `discoverZigFiles` walks
straight into it.

That directory is full of `.zig` files: `zig build`'s C-import shims
(`cimport.zig`), embedded-asset modules, dependency manifests, and
other generated artifacts, none of which are project source. Every one
of them gets treated as a discovered file, and since nothing `@import`s
a path inside `.zig-cache`, every single one is reported as an orphan
file — pure noise that can dwarf the real findings and makes exit-code-
on-orphans (`main.zig` exits non-zero if any orphan files are found)
trigger on a stale cache dir alone.

Measured against `formic/backend`
(`zigroot --root apps/clusterd/src/main.zig --dir backend --build-zig build.zig`,
run after `zig build` had populated `backend/.zig-cache/`): 83 of the
379 reported "orphan files" were paths under `.zig-cache/o/<hash>/`
(`cimport.zig`, `embedded_assets.zig`, `dependencies.zig`), e.g.
`.zig-cache/o/ebf6c1003720ced11c95e6785983535b/dependencies.zig`.

Minimal repro: run `zig build` in any project using the 0.12+ default
cache name to populate `.zig-cache/`, then run zigroot with `--dir`
pointed at that project root — the cache's generated `.zig` files show
up as orphans.

Fix sketch: add `".zig-cache"` to `skip_dirs` in
`Project.discoverZigFiles` (`src/Project.zig`) alongside the existing
`"zig-cache"` entry — keep both since some projects still override the
cache dir name back to the pre-0.12 default via `--cache-dir`.
