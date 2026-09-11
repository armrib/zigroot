# Provenance

The files in this directory are copied from
[ZLint](https://github.com/DonIsaac/zlint) by Don Isaac, MIT licensed
(see `LICENSE`), at commit
`8cbbb1c9c48ebc091d9b230bb98355d53cc251ad` — the last commit before ZLint's
`main` moved to Zig 0.16's `Io`-threaded filesystem API. Only the per-file
semantic-analysis layer was taken: `src/Semantic.zig`, `src/Semantic/*.zig`
(flattened into this directory), `src/Semantic/test/*.zig`, `src/span.zig`,
`src/Error.zig`, `src/util.zig` and `src/util/{id,bitflags,bitflags_test}.zig`.

The upstream layout is kept so diffs against ZLint stay readable; the
import paths were rewritten for the flattened layout (`../Semantic.zig` →
`Semantic.zig`, the `util` named module → `util.zig`).

## Local modifications

- `util.zig`: trimmed to `RUNTIME_SAFETY`, `IS_DEBUG`, `IS_TEST`,
  `@"inline"`, `NominalId`, `Bitflags`, `assert`, `debugAssert`,
  `assertUnsafe`. `env`, `Cow`, `DebugOnly`, `FeatureFlags` and the
  whitespace helpers are gone (nothing in this tree used them).
- `Error.zig`: `message` is a plain slice plus an `owned` flag instead of a
  `Cow`; the `Arc`-shared `source` field (from ZLint's `smart-pointers`
  dependency), `jsonStringify`, `Severity.jsonParse`/`jsonSchema` (from
  ZLint's `json.zig`) and the never-instantiable `newAtLocation` are
  removed. `Result(T).deinit` calls `T.deinit` directly (`T` is always
  `Semantic` here).
- `span.zig`: `LabeledSpan.label` is `?[]const u8` instead of `?Cow`;
  `LabeledSpan.fmtJson`/`LocationFormatter` are removed.
- `Builder.zig`: `_source_code`, `_source_path` and `withSource` (the
  `source.zig`/`Arc` path for attaching a shared source buffer to errors)
  are removed. `build(source)` already takes the sentinel slice directly,
  which is the only entry point zigroot uses. `Error.source_name` is no
  longer filled in; the caller knows which file it built.
- `test/util.zig`: no graphical reporter or `Source`; analysis errors are
  printed plainly. `debugSemantic` (needed ZLint's `printer`) is removed.
- `test/modules_test.zig`: the `withSource` leak test is removed with the
  API.
- `util/bitflags_test.zig`: the `Bitflags.format` expectation uses
  `@typeName` instead of a hard-coded module path.
- `Semantic.zig`: re-exports `Error` (`Error.zig`) and `Location`
  (`span.zig`) so the project layer can keep a file's diagnostics and
  print them with line/column.

Update this list whenever a file in this directory is edited.
