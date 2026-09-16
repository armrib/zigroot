# CLAUDE.md

zigroot is a whole-project reachability analyzer built on ZLint's per-file
`Semantic` layer. It adds file discovery, `@import("*.zig")` resolution, and
cross-file reachability, so dead code reachable only within a cycle of files is
found. Reports orphan files and dead symbols. Built on
[ZLint](https://github.com/DonIsaac/zlint); see the README's "Status" section
(the living design log) before changing `src/*.zig`.

Deliberate semantics:
- Test code isn't use: a declaration only a `test` block reaches is dead; a file
  only a test reaches is test-only (recorded, never analyzed, never an orphan).
- Only declarations are findings: parameters, locals, fields fold into their dead
  parent.

`src/semantic/` is a modified vendored copy of ZLint (MIT). Update
`src/semantic/UPSTREAM.md` whenever you edit a file there; pulling newer upstream
means porting from Zig 0.15 to 0.16's `Io` API. No package deps.

## Tickets

- Track gaps as `issues/NN-*.md`, one per file.
- Each ticket: the gap, a repro, a fix sketch, done criteria.
- Close = delete: landing the fix removes the ticket in the same change; same for
  `docs/TODO*.md` lists — delete what's done.

## Tests

- Keep `zig build test` a suite of pure unit tests: each `Foo_test.zig` tests its
  own subject with synthetic fixtures inline — no shared state, no external corpus.
- Register every new `Foo_test.zig` in the `test { ... }` block at the bottom of
  `src/root.zig` or it never runs.
- `src/self_test.zig` is the only integration test: it analyzes this repo and
  pins expected findings. A declaration newly dead or newly reached fails; new
  `src/semantic/` findings are tolerated. Update its list deliberately.

## Conventions

- New cross-file resolution extends the two existing call sites (`SymbolGraph`
  same-file, `Resolver` cross-file) — no parallel walks.
- No real type inference, by design: only what's written in the source. A fix
  needing inference from usage is out of scope; check `issues/`.
- After changes, run `zig build test` and eyeball `zig build run` output.