//! Turns `Reachability.deadSymbols` + `Scc` into printable findings:
//! one per dead declaration, or one per dead *cycle* (a strongly
//! connected component of mutually-referencing dead declarations, which
//! is a single thing to delete), each located at `path:line:column` with
//! `path` relative to the project root.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");

const Project = @import("Project.zig");
const Reachability = @import("Reachability.zig");
const Scc = @import("Scc.zig");
const SymbolId = @import("SymbolId.zig").SymbolId;

pub const Finding = struct {
    id: SymbolId,
    /// Relative to the `base_dir` passed to `collect`. Owned.
    path: []const u8,
    /// 1-based, of the declaration's name token (or the declaration node
    /// when it has none).
    line: u32,
    column: u32,
    /// `fn`, `const`, `var`, `struct`, `enum`, `union`, `error set`.
    kind: []const u8,
    name: []const u8,
    /// Dead descendants folded into this finding — see
    /// `Reachability.deadSymbols`.
    nested: usize,
    /// Only reached through an `.unknown` edge (a runtime-named
    /// `@field(...)`) from live code: not certainly dead.
    possible: bool,
    /// Every member of the dead cycle this finding stands for, `id`
    /// included; empty for a plain declaration. Borrows `Scc`.
    cycle: []const SymbolId,

    fn lessThan(_: void, a: Finding, b: Finding) bool {
        switch (std.mem.order(u8, a.path, b.path)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (a.line != b.line) return a.line < b.line;
        return a.column < b.column;
    }
};

pub const Location = struct { line: u32, column: u32 };

/// Where `id` is declared: its name token if ZLint recorded one, else the
/// start of its declaration node.
pub fn locate(project: *const Project, id: SymbolId) Location {
    const f = project.file(id.file);
    const sym = f.semantic.symbols.get(id.local);
    const span = if (sym.token.unwrap()) |tok| f.semantic.tokenSpan(@intFromEnum(tok)) else f.semantic.nodeSpan(sym.decl);
    const loc = Semantic.Location.fromSpan(f.source, span);
    return .{ .line = loc.line, .column = loc.column };
}

pub fn kindOf(sym: *const Semantic.Symbol) []const u8 {
    if (sym.flags.s_fn) return "fn";
    if (sym.flags.s_struct) return "struct";
    if (sym.flags.s_enum) return "enum";
    if (sym.flags.s_union) return "union";
    if (sym.flags.s_error) return "error set";
    if (sym.flags.s_variable and !sym.flags.s_const) return "var";
    return "const";
}

/// Every dead declaration as a `Finding`, a dead cycle collapsed into one
/// (anchored on whichever member `deadSymbols` listed first), sorted by
/// path, then line, then column. `base_dir` is what paths are made
/// relative to — the directory holding `build.zig`. Caller owns the list
/// (free with `deinit`).
pub fn collect(
    gpa: Allocator,
    project: *const Project,
    dead: []const Reachability.Dead,
    scc: *const Scc,
    base_dir: []const u8,
) !std.ArrayListUnmanaged(Finding) {
    var findings: std.ArrayListUnmanaged(Finding) = .empty;
    errdefer deinit(&findings, gpa);

    var reported_cycles: std.AutoHashMapUnmanaged(Scc.ComponentId, void) = .empty;
    defer reported_cycles.deinit(gpa);

    for (dead) |d| {
        const sym = project.symbol(d.id);
        if (sym.name.len == 0) continue;

        var cycle: []const SymbolId = &.{};
        if (scc.componentOf(d.id)) |component| {
            if (scc.isCyclic(component)) {
                if (reported_cycles.contains(component)) continue;
                try reported_cycles.put(gpa, component, {});
                cycle = scc.members(component);
            }
        }

        const abs = project.file(d.id.file).path;
        const rel = std.fs.path.relative(gpa, base_dir, abs) catch try gpa.dupe(u8, abs);
        errdefer gpa.free(rel);
        const loc = locate(project, d.id);
        try findings.append(gpa, .{
            .id = d.id,
            .path = rel,
            .line = loc.line,
            .column = loc.column,
            .kind = kindOf(&sym),
            .name = sym.name,
            .nested = d.nested,
            .possible = d.possible,
            .cycle = cycle,
        });
    }

    std.mem.sort(Finding, findings.items, {}, Finding.lessThan);
    return findings;
}

pub fn deinit(findings: *std.ArrayListUnmanaged(Finding), gpa: Allocator) void {
    for (findings.items) |f| gpa.free(f.path);
    findings.deinit(gpa);
}

/// Prints `finding` as `path:line:column: kind name`, plus ` (+N nested)`
/// and, for a cycle, ` (cycle of N: a, b, ...)`.
pub fn print(project: *const Project, finding: Finding) void {
    std.debug.print("  {s}:{d}:{d}: {s} {s}", .{ finding.path, finding.line, finding.column, finding.kind, finding.name });
    if (finding.nested > 0) std.debug.print(" (+{d} nested)", .{finding.nested});
    if (finding.cycle.len > 0) {
        std.debug.print(" (cycle of {d}:", .{finding.cycle.len});
        var first = true;
        for (finding.cycle) |member| {
            const name = project.symbol(member).name;
            if (name.len == 0) continue;
            std.debug.print("{s} {s}", .{ if (first) "" else ",", name });
            first = false;
        }
        std.debug.print(")", .{});
    }
    std.debug.print("\n", .{});
}
