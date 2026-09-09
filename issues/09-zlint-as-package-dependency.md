# Depend on ZLint as a package instead of a `vendor/` submodule

`vendor/zlint` is a git submodule pinned via `.gitmodules`, referenced from
`build.zig.zon` as a local `.path = "vendor/zlint"` dependency. That means
every clone needs `git submodule update --init`, there's no content hash
pinning the exact source that gets built, and picking up a new ZLint
release means bumping a submodule commit rather than a `zig fetch`.

Should switch to a normal Zig package dependency: `zig fetch --save` a
tagged ZLint release (or its git URL) so `build.zig.zon` gets a `url` +
`hash` entry, drop `vendor/zlint` and `.gitmodules`, and let the package
manager cache the source under `~/.cache/zig` instead of the repo tree.
