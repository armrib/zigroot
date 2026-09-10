# `allocator.create(T)`-typed variables don't resolve instance-method calls

`InstanceType.resolve`/`callInit` handle a call-init variable
(`var s = Foo.init(...)`) by extracting the callee and resolving *its*
declared return type (`fnReturnTypeNode`) — that only works when the
callee is a project-local function with a readable return-type
annotation. `std.mem.Allocator.create(comptime T: type) Error!*T` is a
different shape: the callee lives in `std` (no AST to read a return
type off), and the pointee type isn't a return annotation at all — it's
spelled out as `T` in the *call's own argument list*. `callInit` doesn't
special-case this, so `resolve` falls through and the variable's type
stays unresolved.

That's a real, common Zig idiom (`const x = try allocator.create(Foo);`
followed immediately by `x.method()`), and it cascades badly: every
instance-method call on `x` is unresolved, so every method it
transitively reaches is unreachable-from-roots, so a whole subsystem can
be misreported dead.

Measured against `formic/backend`
(`zigroot --root apps/iamd/src/main.zig --dir apps/iamd/src --build-zig build.zig`,
run from `backend/`): `apps/iamd/src/main.zig:818-820` does
`const server = try allocator.create(http.HttpServer); ... http.HttpServer.init(server, ...); ... server.run();`
(`main.zig:1123`). `HttpServer.run` and everything it calls —
`handleAccept`, `handleRecv`, `onAccept`, `onSend`, `stopAcceptingNew`,
dozens of others in `apps/iamd/src/server/Http.zig` — are reported as
dead declarations, despite `run()` being the server's actual event
loop, directly invoked from `main`.

Minimal repro:
```zig
// src/foo.zig
pub const Foo = struct {
    pub fn run(self: *Foo) void { _ = self; }
};

// src/main.zig
const std = @import("std");
const foo = @import("foo.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const server = try allocator.create(foo.Foo);
    server.run();
}
```
`zigroot --root src/main.zig --dir src` reports `foo.zig: run` as a
dead declaration, though it's called directly from `main`.

Fix sketch: in `InstanceType.callInit` (or a sibling helper reached from
`resolve`), recognize a call whose callee is a member-access ending in
`.create` (matching `Allocator.create`) and whose first argument is a
type expression (`fullCall`'s `ast.params[0]`, resolved the same way
`resolveTypeExpr` resolves any other type-position node) — return that
argument's node directly instead of trying to read a return-type
annotation off the (external, unreadable) callee. This is still
"syntactically spelled out," just in argument position instead of
return-type position, so it fits the project's non-inference scope.
