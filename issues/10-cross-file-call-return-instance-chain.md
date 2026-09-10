# Cross-file call-return instance chain

```zig
// table.zig
pub const ChannelTable = struct {
    pub fn get_or_open(self: *ChannelTable, id: u32) !*ChannelLog { ... }
};

// caller.zig (different file, `state.channels: table.ChannelTable`)
const channel_log = state.channels.get_or_open(id) catch { ... };
channel_log.append(...);
```

`state.channels.get_or_open(id)`'s callee is itself an instance-field
chain (`state.channels`, a container field whose declared type crosses
an `@import` boundary), not a plain `Container.method` path.
`Resolver.callInstanceType` (`src/Resolver.zig`) already handles `var s
= Foo.init(...)` by resolving the callee through `resolveValueChain`,
but that function only walks `identifier`/`field_access` hops through
`hop`/`FieldChain.findExport` against each symbol's own exports — it
never redirects through a field's *declared type* the way
`FieldChain.resolveChain` does for a value-position chain. So
`resolveValueChain`'s first hop (`state`) has no exports of its own
(it's a variable, not a container), the walk fails, `channel_log`'s
type is never inferred, and every instance method reachable only
through it (`append`, `fetch_before`, `close`, ...) is reported dead.

Confirmed with a minimal repro (two files: a `Table.get()` returning
`*Inner`, and `state.table.get().used_only_via_chain()`) — reproduces
outside any real corpus.

Measured impact: running zigroot against `formic/demos/chat/backend`
(`state.channels.get_or_open(id) catch {...}; channel_log.append(...)`
/ `.fetch_before(...)`) misreports `msg_log.zig`'s `close`, `append`,
`fetch_before`, `scan_backward`, `write_all` (~140 lines) and, via
`fetch_before`'s own now-invisible calls, `ring_buf.zig`'s `tail`,
`len`, `iter_recent`, `Entry.payload` and `msg_record.zig`'s
`serialize`, `frame` as dead.

Fix sketch: `resolveValueChain`'s `field_access` case (or `hop`) should
fall back to `FieldChain`'s declared-type redirection — when `hop`'s
first attempt (`FieldChain.findExport` against the symbol itself)
fails, resolve the symbol's own declared type the way
`InstanceType.resolve`/`crossFileRoot` do, and continue the hop against
that type's exports/cross-file target instead of giving up.
