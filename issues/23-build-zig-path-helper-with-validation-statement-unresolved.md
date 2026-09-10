# A `b.path(...)` pass-through helper with a leading validation statement stays unresolved

```zig
fn srcPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    b.build_root.handle.access(sub_path, .{}) catch |err| std.debug.panic(
        "build.zig: root_source_file does not resolve: '{s}' ({s})",
        .{ sub_path, @errorName(err) },
    );
    return b.path(sub_path);
}

pub fn build(b: *std.Build) void {
    const foo_mod = b.createModule(.{ .root_source_file = srcPath(b, "src/foo.zig"), ... });
    ...
}
```

`foo.zig` is reported as an orphan file even though `--build-zig` is passed and
`foo_mod` is wired into the executable's module graph. Reducing `srcPath` to
its single `return b.path(sub_path);` statement (dropping the `.access(...)
catch ... panic(...)` validation call) makes it resolve correctly.

Found running zigroot against formic's `workflow` backend: its `build.zig`
defines exactly this two-statement `srcPath` helper (validate the path
exists, then delegate to `b.path`) and uses it for every one of ~20
`createModule` calls, so every module in the project's actual dependency
graph — `types`, `config`, `scheduler`, `engine`, the whole `compiler/`
and `runtime/` trees — is left unresolved and every file in `src/`
reported orphaned, exactly the situation `--build-zig` exists to fix.

Root cause: `BuildGraph.passThroughPathParamIndex` (`src/BuildGraph.zig`,
added in the immediately preceding fix for issues/19) requires the
callee's body to be *exactly one statement* (`if (stmts.len != 1) return
null;`) before it will even look at whether that statement is `return
<recv>.path(<param>);`. That fix's own doc comment on `pathThroughHelperCall`
already describes the target shape as "a thin pass-through wrapper around
`b.path(...)`, e.g. one that also validates the path exists first" — i.e.
this exact leading-statement shape was the motivating case — but the
statement-count check never got relaxed to allow it.

Fix sketch: `passThroughPathParamIndex` should accept a body of N
statements where the last is `return <recv>.path(<param>);` and every
statement before it is anything else (their contents don't matter — only
the return's shape and the returned `LazyPath` need matching), rather than
requiring the body be exactly that one return statement. `stmts.len != 1`
becomes `stmts.len == 0`, and the `.@"return"` check moves from
`stmts[0]` to `stmts[stmts.len - 1]`.
