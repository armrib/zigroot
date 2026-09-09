# Test-harness reachability across many files

`linter/tester.zig` (26 dead lines) and
`reporter/formatters/GraphicalFormatter.zig` (32 dead lines) are each
used from `test { ... }` blocks spread across ~17 different
`linter/rules/*.zig` files in `vendor/zlint`, yet still show up dead in a
measured run. Not yet root-caused — worth checking whether this is
downstream of issue 1 (test bodies calling instance methods on
`self`-like locals) or a separate gap in how `Roots`' `.test`-root case
walks test-block references.
