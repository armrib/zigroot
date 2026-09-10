# Separate per-file test binaries aren't reachability roots

`Roots`' `.test` case only finds roots by scanning `test { ... }` blocks
inside files already loaded into the project (see
`Roots.zig`'s module doc). It has no way to know about a `build.zig`
pattern where each test file is its own `b.addTest` root module —
compiled and run as a standalone binary, never `@import`ed from
anywhere — rather than an inline `test { ... }` block inside a
production file.

Measured against `formic/backend/apps/staticd`
(`zigroot --root apps/staticd/src/main.zig --dir apps/staticd --build-zig apps/staticd/build.zig`):
`apps/staticd/build.zig` wires five files under `src/tests/` as their own
`b.addTest({ .root_module = ... })` targets (`test_admin.zig`,
`test_http.zig`, `test_image.zig`, `test_mph.zig`, `test_path.zig`,
plus `test_handler.zig` and `test_engine.zig` each with a dedicated
`b.createModule`). None of them are `@import`ed from `main.zig` or any
other file `main.zig`'s import graph reaches, so zigroot reports all
seven as orphan files. Worse, `engine.zig` and `handler.zig` each carry
`pub const` re-exports that exist *only* so the corresponding test file
can reach a sibling module through them (`pub const admin_mod = admin;`,
`pub const loader_mod = loader;`, `pub const conn = conn_mod;` in
`engine.zig`; `pub const http_mod = http;`, `pub const loader_mod =
loader;`, `pub const conn = conn_mod;` in `handler.zig`) — each is
reported as a dead declaration even though it's live production code
whose only consumer is a legitimate, build.zig-registered test binary.

Root-causing: `Roots` would need to know, for a given `--build-zig`,
which modules are wired via `b.addTest` (as opposed to
`b.addExecutable`/`b.createModule` used only as a dependency) so their
root file can seed a `.test`-flavored root of its own, the same way an
inline `test { ... }` block does today. `BuildGraph`'s syntactic scan
already walks `addImport`/`createModule` shapes; it would need to also
recognize `b.addTest({ .root_module = <local binding> })` (or the older
`.root_source_file = ...` shape) and surface those root files back to
`Roots`/`Project` so `--build-zig` users get them for free instead of
needing a separate `--root` per test file.
