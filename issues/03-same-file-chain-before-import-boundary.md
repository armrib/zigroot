# Same-file chain before crossing an `@import` boundary

`var s: mod.storage.Widget = ...;` — `InstanceType.crossFileRoot` only
recognizes a *single* `base.field` hop off a plain identifier as the
unresolved-cross-file shape; a same-file chain (`mod.storage`) leading up
to the `@import`-crossing hop isn't attempted. Noted as a gap since Phase
15 of the (now-removed) roadmap.
