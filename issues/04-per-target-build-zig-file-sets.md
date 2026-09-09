# Per-target file sets in `build.zig`

`BuildGraph` resolves one `root_source_file` per module regardless of
build options, so a conditionally-selected file (`linux.zig` vs
`windows.zig` picked by `target.os.tag`) always resolves to whichever
branch's `b.path(...)` its syntactic scan finds first. Genuinely
evaluating `build.zig`'s control flow would mean actually running it —
noted as "later / not scheduled" since the `build.zig` module graph
integration phase landed.
