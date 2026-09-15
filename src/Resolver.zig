//! Phase 6: cross-file `Symbol -> Symbol` edges through `@import`.
//!
//! `SymbolGraph` (Phase 4) only sees references within one file. This fills
//! in the other half: `const storage = @import("storage.zig");
//! storage.start();` binds `storage` to a symbol whose declaration node
//! *is* the `@import(...)` call — found the same way `OwnerMap` finds any
//! declaration containing a node. A reference to that binding used as the
//! base of a field access (`storage.start`) is then matched by name against
//! the target file's exported symbols (ZLint's `Symbol.exports`, on the
//! implicit file-root symbol every top-level declaration is exported from).
//!
//! After that first hop, Phase 7's `FieldChain` continues resolving further
//! `container.member` hops entirely within the target file (e.g.
//! `storage.Inner.run()`), so static-member access chains through an
//! `@import` boundary too.
//!
//! Phase 12: a reference to the binding used as the container argument of
//! `@field(storage, name)` is resolved the same way, via `DynamicField`
//! against the target file's exports — a comptime-known name at `.possible`
//! confidence, a runtime name as `.unknown` edges to every export.
//!
//! Phase 13: whichever hop crosses the `@import` boundary (a plain
//! `storage.start` or a comptime-known `@field(storage, "start")`), further
//! hops within the target file use `FieldChain.resolveChain`, so `.field`
//! and `@field(...)` hops keep interleaving past the boundary too —
//! `storage.field("Bar").baz` or `@field(storage, "Inner").run()` chain as
//! far as they resolve, same as the same-file case in `SymbolGraph`.
//!
//! Phase 15: `InstanceType`'s same-file variable-type resolution
//! (`var s: Foo = ...; s.run();`) gets the same cross-file treatment —
//! `var s: storage.Widget = ...; s.run();` resolves `storage.Widget` into
//! the target file's exports the same way `storage.start()` does above,
//! then chains `s`'s own references the same way `FieldChain` does for the
//! same-file case.
//!
//! Phase 17: `var s = Foo.init(...); s.run();` — Zig requires a function's
//! return type to be spelled out, so it's as legitimate a "type written
//! down" as `InstanceType`'s other two shapes (an annotation, a typed
//! struct-literal initializer); the missing piece is resolving what the
//! callee (`Foo.init`) and its return-type expression actually name.
//! `resolveValueChain` does that: unlike `FieldChain`/`InstanceType`, which
//! stay within one file or cross exactly one `@import` boundary, it keeps
//! hopping across as many as the expression does — needed since a resolved
//! hop can itself be bound to another `@import` (a re-export, e.g. `pub
//! const Builder = @import("Builder.zig")` inside a file already crossed
//! into). A `const Self = @This();` (or any name) alias — the plain
//! `const` a container names itself with, which otherwise has no exports
//! of its own to match a further hop against — is handled by
//! `FieldChain.findExport` itself, so every hop through this walk gets it
//! for free.
//!
//! Phase 20: `const Schema = @import("json.zig").Schema;` binds to one
//! export of the target file, not the whole file, right at the
//! `@import(...)` call — `aliasRoot` detects this and resolves every
//! reference to the binding (further field hops and bare uses alike)
//! against that export instead of the target file's root.
//!
//! Phase 30: value aliases and decl literals. `const Project =
//! zigroot.Project;` (where `zigroot.Project` is itself `pub const Project
//! = @import("Project.zig")` in another file) is a plain `const` with no
//! exports of its own; a chain that lands on it (`var p: Project = ...;
//! p.load()`, `Project.init(...)`) is finished by `resolveAlias`, which
//! resolves the alias's initializer through `resolveValueChain` — now also
//! understanding a bare `@import(...)` call as the target file's root — and
//! resumes the walk wherever that lands, however many files away.
//! `buildDeclLiterals` gives `var p: Project = .init(gpa);` /
//! `return .empty;` (see `DeclLiteral`) the same cross-file treatment
//! `SymbolGraph` gives them same-file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Semantic = @import("semantic/Semantic.zig");
const Ast = Semantic.Ast;

const Project = @import("Project.zig");
const File = @import("File.zig");
const ImportGraph = @import("ImportGraph.zig");
const FileId = @import("FileId.zig").FileId;
const SymbolId = @import("SymbolId.zig").SymbolId;
const SymbolGraph = @import("SymbolGraph.zig");
const FieldChain = @import("FieldChain.zig");
const DynamicField = @import("DynamicField.zig");
const InstanceType = @import("InstanceType.zig");
const OwnerMap = @import("OwnerMap.zig");
const DeclLiteral = @import("DeclLiteral.zig");

/// Every file's top-level declarations are exported from this symbol.
/// ZLint's `SemanticBuilder.enterRoot` always creates it first, so its id is
/// always 0.
const FILE_ROOT_SYMBOL: Semantic.Symbol.Id = @enumFromInt(0);

/// Builds cross-file edges for every resolved `@import("file.zig")` binding
/// in `project`: for each reference to the binding used as a field-access
/// base, an edge from the referencing declaration to the target file's
/// same-named export, if one exists.
pub fn build(gpa: Allocator, project: *const Project) Allocator.Error!SymbolGraph {
    var graph: SymbolGraph = .empty;
    errdefer graph.deinit(gpa);

    for (project.import_graph.edges.items) |import_edge| {
        const from_file = project.file(import_edge.from);
        const binding = from_file.owner_map.get(import_edge.node) orelse continue;
        const target_file = project.file(import_edge.to);
        const target_semantic = &target_file.semantic;

        // `const Schema = @import("json.zig").Schema;` narrows the binding
        // to one export of the target file right at the `@import(...)`
        // call itself, rather than the whole file root — see `aliasRoot`.
        const import_root = aliasRoot(&from_file.semantic, import_edge.node, target_semantic, &target_file.owner_map) orelse FILE_ROOT_SYMBOL;

        // Phase 34: `@import("main").services_handler.collectServices`
        // written inline, mid-expression, has no binding of its own whose
        // references could be walked — `binding` is the nearest enclosing
        // declaration, and its references are references to *it*. But that
        // declaration is exactly what uses the member, so edge it here and
        // let `addChain` carry the rest of the chain across. Harmless for
        // the `const Schema = @import("json.zig").Schema;` shape: the same
        // edge is what `buildAliasEdges` records, and duplicates are fine.
        if (import_root != FILE_ROOT_SYMBOL) {
            const owner_id: SymbolId = .{ .file = import_edge.from, .local = binding };
            const target_id: SymbolId = .{ .file = import_edge.to, .local = import_root };
            try graph.addEdge(gpa, owner_id, target_id, import_edge.node, .definite);
            if (from_file.semantic.node_links.getParent(import_edge.node)) |field_node| {
                try addChain(project, &graph, gpa, owner_id, import_edge.to, &from_file.semantic, target_semantic, &target_file.owner_map, import_root, field_node, .definite);
            }
        }

        var ref_it = from_file.semantic.symbols.iterReferences(binding);
        while (ref_it.next()) |ref| {
            const owner = ownerOf(from_file, ref.node) orelse continue;
            const owner_id: SymbolId = .{ .file = import_edge.from, .local = owner };

            if (FieldChain.fieldAccessName(&from_file.semantic, ref.node)) |field_name| {
                const target_local = FieldChain.findExport(target_semantic, &target_file.owner_map, import_root, field_name) orelse continue;
                const field_node = from_file.semantic.node_links.getParent(ref.node).?;
                // The export named right after the boundary is referenced
                // whether or not the chain continues past it (`zigroot.Roots`
                // in `zigroot.Roots.build(...)`).
                try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = target_local }, field_node, .definite);
                try addChain(project, &graph, gpa, owner_id, import_edge.to, &from_file.semantic, target_semantic, &target_file.owner_map, target_local, field_node, .definite);
                continue;
            }

            if (DynamicField.resolve(&from_file.semantic, target_semantic, import_root, ref.node)) |resolution| {
                switch (resolution) {
                    .possible => |target| {
                        const field_node = from_file.semantic.node_links.getParent(ref.node).?;
                        try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = target }, field_node, .possible);
                        try addChain(project, &graph, gpa, owner_id, import_edge.to, &from_file.semantic, target_semantic, &target_file.owner_map, target, field_node, .possible);
                    },
                    .unknown => |exports| for (exports) |target| {
                        try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = target }, ref.node, .unknown);
                    },
                }
                continue;
            }

            // A bare reference to an alias binding narrowed by `import_root`
            // above (e.g. `Schema{...}`, `fn f() Schema`) — nothing further
            // to chase, but the aliased declaration itself is what needs to
            // be reachable, not just its own further field hops.
            if (import_root != FILE_ROOT_SYMBOL) {
                try graph.addEdge(gpa, owner_id, .{ .file = import_edge.to, .local = import_root }, ref.node, .definite);
            }
        }
    }

    try buildInstanceTypes(gpa, &graph, project);
    try buildCallInstanceTypes(gpa, &graph, project);
    try buildStuckFieldChains(gpa, &graph, project);
    try buildDeclLiterals(gpa, &graph, project);
    try buildAliasEdges(gpa, &graph, project);
    try buildAnonymousContainerMembers(gpa, &graph, project);
    try buildDuckTypedArguments(gpa, &graph, project);
    try buildAnonymousReturnMembers(gpa, &graph, project);

    return graph;
}

/// Phase 30: using a value alias uses what it names. `const NominalId =
/// util.NominalId;` referenced bare (`NominalId(u32, ...)`) never goes
/// through a `.field` hop that could resolve it, so the alias symbol is
/// reached but its target never is. One edge per alias — `@import`
/// bindings included, so a file used as a namespace also reaches its
/// root (and, through `SymbolGraph`'s container→field edges, the types its
/// top-level fields are declared with).
fn buildAliasEdges(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        var sym_it = file.semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            if (FieldChain.valueAliasInit(&file.semantic, sym_id, .{ .allow_call = true }) == null) continue;
            const alias: SymbolId = .{ .file = file.id, .local = sym_id };
            const target = resolveAlias(project, alias) orelse continue;
            if (target.eql(alias)) continue;
            try graph.addEdge(gpa, alias, target, file.semantic.symbols.get(sym_id).decl, .definite);
        }
    }
}

/// Phase 38: the declaration a reference at `node` belongs to. A reference
/// written straight inside a container-level `test { ... }` block has none —
/// which is the whole point, since test code doesn't count as use. In a
/// *test-only file* the entire file is that block, so the file's own root
/// symbol stands in: `Roots.buildTestBlockRoots` seeds it, and a production
/// walk can never reach it, because nothing outside test code imports such a
/// file in the first place.
fn ownerOf(file: *const File, node: Semantic.Ast.Node.Index) ?Semantic.Symbol.Id {
    if (file.owner_map.get(node)) |owner| return owner;
    if (file.test_only) return FILE_ROOT_SYMBOL;
    return null;
}

/// The symbol whose own declaration node is `node`. `OwnerMap` answers the
/// other question — which declaration *contains* a node — so it can't be used
/// to walk from a container's member list to the members themselves.
fn symbolDeclaredAt(semantic: *const Semantic, node: Semantic.Ast.Node.Index) ?Semantic.Symbol.Id {
    var it = semantic.symbols.iter();
    while (it.next()) |sym_id| {
        if (semantic.symbols.get(sym_id).decl == node) return sym_id;
    }
    return null;
}

/// Phase 43: `const acquired = pool.acquire() orelse return;
/// acquired.worker.stageVerifyRequest(...)`, where `acquire` returns
/// `?struct { id: u16, worker: *ArgonWorker }`. The return type is an
/// anonymous container, so there is no symbol to hand back as `acquired`'s
/// type and every hop off it goes unresolved — taking the whole
/// `ArgonWorker` method set with it. Match the hop's field name against the
/// return type's own member list (as Phase 39 does for a literal written
/// inline), then resume the walk from that member's declared type.
fn buildAnonymousReturnMembers(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;
        const ast = &semantic.parse.ast;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            const ret = anonymousReturnType(project, file.id, sym_id) orelse continue;
            const ret_semantic = &project.file(ret.file).semantic;

            // Re-read the members here: `fullContainerDecl` writes a
            // two-member list into the buffer it is handed, so a slice
            // returned across a function boundary would dangle.
            var buf: [2]Ast.Node.Index = undefined;
            const container = ret_semantic.parse.ast.fullContainerDecl(&buf, ret.node) orelse continue;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = ownerOf(&file, ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };

                const hop_node = semantic.node_links.getParent(ref.node) orelse continue;
                if (ast.nodeTag(hop_node) != .field_access) continue;
                const wanted = semantic.tokenSlice(ast.nodeData(hop_node).node_and_token[1]);

                for (container.ast.members) |member| {
                    const member_sym = symbolDeclaredAt(ret_semantic, member) orelse continue;
                    const member_id: SymbolId = .{ .file = ret.file, .local = member_sym };
                    if (!std.mem.eql(u8, project.symbol(member_id).name, wanted)) continue;

                    try graph.addEdge(gpa, owner_id, member_id, hop_node, .definite);

                    const ty = declaredType(project, member_id) orelse continue;
                    const ty_file = project.file(ty.file);
                    try graph.addEdge(gpa, owner_id, ty, hop_node, .possible);
                    try addChain(project, graph, gpa, owner_id, ty.file, semantic, &ty_file.semantic, &ty_file.owner_map, ty.local, hop_node, .possible);
                }
            }
        }
    }
}

const AnonymousReturn = struct {
    /// The file the callee — and so the type node — lives in, which is not
    /// `sym_id`'s file whenever the call crossed an `@import`.
    file: FileId,
    node: Ast.Node.Index,
};

/// The anonymous container `sym_id`'s call initializer returns, if that is
/// what its callee's declared return type is. `null` whenever the type has
/// a name — every other case already resolves.
fn anonymousReturnType(project: *const Project, file_id: FileId, sym_id: Semantic.Symbol.Id) ?AnonymousReturn {
    const semantic = &project.file(file_id).semantic;
    const fn_expr = InstanceType.callInit(semantic, sym_id) orelse return null;
    const fn_sym = resolveValueChain(project, file_id, fn_expr) orelse return null;

    const fn_semantic = &project.file(fn_sym.file).semantic;
    const return_node = InstanceType.fnReturnTypeNode(fn_semantic, fn_sym.local) orelse return null;

    var buf: [2]Ast.Node.Index = undefined;
    if (fn_semantic.parse.ast.fullContainerDecl(&buf, return_node) == null) return null;
    return .{ .file = fn_sym.file, .node = return_node };
}

/// Phase 40: `pwriteFull(FdWriter{ .fd = fd }, bytes, offset)`, where
/// `pwriteFull` declares `writer: anytype` and calls `writer.write(...)`;
/// and `std.HashMap(K, V, KeyContext, ...)`, where the generic picking
/// `hash`/`eql` off `KeyContext` lives in a module this project never
/// analyzes. Both hand a container type to code that reaches into it by
/// name, and in neither case does that name appear anywhere visible: the
/// only `write` caller is inside an `anytype` body, the only `hash` caller
/// is inside `std`. Which members get used is not knowable, so every export
/// of the argument's type is edged at `.unknown` — the same standing
/// `@field(Foo, runtime_name)` already has, and for the same reason.
fn buildDuckTypedArguments(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const ast = &file.semantic.parse.ast;
        for (0..ast.nodes.len) |raw| {
            const node: Semantic.Ast.Node.Index = @enumFromInt(raw);
            var call_buf: [1]Semantic.Ast.Node.Index = undefined;
            const call = ast.fullCall(&call_buf, node) orelse continue;
            const owner = ownerOf(&file, node) orelse continue;
            const owner_id: SymbolId = .{ .file = file.id, .local = owner };

            const callee = resolveValueChain(project, file.id, call.ast.fn_expr);
            for (call.ast.params, 0..) |arg, index| {
                if (!isDuckTypedParam(project, file.id, call.ast.fn_expr, callee, index)) continue;
                const ty = argumentType(project, file.id, arg) orelse continue;

                // Phase 54: when the callee is a project function, its body
                // says exactly which chains it walks off the parameter
                // (`server.file_ops.unlink(...)`). Walking those against the
                // concrete type beats guessing at its whole export set, and
                // reaches past the first hop, which the guess never did.
                if (callee) |fn_sym| {
                    if (try walkDuckChains(gpa, graph, project, owner_id, fn_sym, index, ty)) continue;
                }

                const exports = project.file(ty.file).semantic.symbols.get(ty.local).exports;
                for (exports.items) |member| {
                    try graph.addEdge(gpa, owner_id, .{ .file = ty.file, .local = member }, node, .unknown);
                }
            }
        }
    }
}

/// Whether argument `index` of a call to `callee` lands on a parameter whose
/// members can be reached by a name this analysis can't see: an `anytype`
/// parameter of a function it does see, or any parameter of a generic
/// reached through an external module (`std.HashMap`). A callee that simply
/// didn't resolve is *not* treated this way — most of those are ordinary
/// method calls, and assuming the worst of them would edge half the project.
/// Re-walks every `.field` chain the callee's `index`-th parameter is the
/// base of, but against `ty` — the type the call site actually passed. Edges
/// land on the call site's owner, since that is the code whose use of the
/// argument justifies them. Returns whether any chain was walked at all;
/// when none was, the caller falls back to the whole-export-set guess.
fn walkDuckChains(
    gpa: Allocator,
    graph: *SymbolGraph,
    project: *const Project,
    owner_id: SymbolId,
    fn_sym: SymbolId,
    index: usize,
    ty: SymbolId,
) Allocator.Error!bool {
    const param = paramSymbolAt(project, fn_sym, index) orelse return false;
    const callee_file = project.file(fn_sym.file);
    const ty_file = project.file(ty.file);

    var walked = false;
    var ref_it = callee_file.semantic.symbols.iterReferences(param);
    while (ref_it.next()) |ref| {
        try addChain(project, graph, gpa, owner_id, ty.file, &callee_file.semantic, &ty_file.semantic, &ty_file.owner_map, ty.local, ref.node, .possible);
        walked = true;
    }
    return walked;
}

/// The symbol bound to `fn_sym`'s `index`-th parameter, matched by the name
/// token the prototype gives it. `null` for an unnamed parameter.
fn paramSymbolAt(project: *const Project, fn_sym: SymbolId, index: usize) ?Semantic.Symbol.Id {
    const semantic = &project.file(fn_sym.file).semantic;
    const symbol = semantic.symbols.get(fn_sym.local);
    if (!symbol.flags.s_fn) return null;

    const ast = &semantic.parse.ast;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&proto_buf, symbol.decl) orelse return null;

    var it = proto.iterate(ast);
    var i: usize = 0;
    while (it.next()) |param| : (i += 1) {
        if (i != index) continue;
        const name_token = param.name_token orelse return null;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            const token = semantic.symbols.get(sym_id).token.unwrap() orelse continue;
            if (token.int() == name_token) return sym_id;
        }
        return null;
    }
    return null;
}

fn isDuckTypedParam(
    project: *const Project,
    file_id: FileId,
    fn_expr: Semantic.Ast.Node.Index,
    callee: ?SymbolId,
    index: usize,
) bool {
    if (callee) |fn_sym| return isAnytypeParam(project, fn_sym, index);
    return callsExternalModule(project, file_id, fn_expr);
}

/// Whether `fn_sym`'s parameter at `index` is declared `anytype`.
fn isAnytypeParam(project: *const Project, fn_sym: SymbolId, index: usize) bool {
    const semantic = &project.file(fn_sym.file).semantic;
    const symbol = semantic.symbols.get(fn_sym.local);
    if (!symbol.flags.s_fn) return false;

    const ast = &semantic.parse.ast;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&proto_buf, symbol.decl) orelse return false;

    var it = proto.iterate(ast);
    var i: usize = 0;
    while (it.next()) |param| : (i += 1) {
        if (i != index) continue;
        return param.type_expr == null and param.anytype_ellipsis3 != null;
    }
    return false;
}

/// Whether `fn_expr`'s base identifier is one of `file_id`'s `@import`
/// bindings for a module outside this project (`std` and friends). The
/// generic behind it is never analyzed, so nothing it names is visible.
fn callsExternalModule(project: *const Project, file_id: FileId, fn_expr: Semantic.Ast.Node.Index) bool {
    const file = project.file(file_id);
    const ast = &file.semantic.parse.ast;

    var base = fn_expr;
    while (ast.nodeTag(base) == .field_access) {
        base = ast.nodeData(base).node_and_token[0];
    }
    if (ast.nodeTag(base) != .identifier) return false;
    const base_sym = InstanceType.referenceAt(&file.semantic, base) orelse return false;

    for (project.import_graph.unresolved.items) |unresolved| {
        if (unresolved.from != file_id) continue;
        if (unresolved.reason != .external) continue;
        const binding = file.owner_map.get(unresolved.node) orelse continue;
        if (binding == base_sym) return true;
    }
    return false;
}

/// The container symbol an argument expression's *type* names: `Foo{...}`
/// through its literal type, a bare `Foo`/`mod.Foo` through the chain it
/// spells. `null` for a value whose type isn't written at the call site.
fn argumentType(project: *const Project, file_id: FileId, arg: Semantic.Ast.Node.Index) ?SymbolId {
    const semantic = &project.file(file_id).semantic;
    const ast = &semantic.parse.ast;

    var buf: [2]Ast.Node.Index = undefined;
    if (ast.fullStructInit(&buf, arg)) |struct_init| {
        const type_expr = struct_init.ast.type_expr.unwrap() orelse return null;
        return resolveTypeNode(project, file_id, type_expr);
    }
    return switch (ast.nodeTag(arg)) {
        .identifier, .field_access => resolveValueChain(project, file_id, arg),
        else => null,
    };
}

/// Phase 39: `std.mem.sort(T, xs, {}, struct { fn lessThan(...) ... }.lessThan)`
/// — a comparator written inline as a member of an anonymous struct. The
/// struct is never named, so no binding exists whose references could be
/// walked, and ZLint never pushes an anonymous `struct { ... }` as a
/// container of its own, so `FieldChain` has nothing to resolve the hop
/// against either. The only mention of `lessThan` anywhere in the project is
/// this one field access. Match the field name against the literal's own
/// member list and edge the enclosing declaration straight to it.
fn buildAnonymousContainerMembers(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const ast = &file.semantic.parse.ast;
        for (0..ast.nodes.len) |raw| {
            const node: Semantic.Ast.Node.Index = @enumFromInt(raw);
            if (ast.nodeTag(node) != .field_access) continue;

            const data = ast.nodeData(node).node_and_token;
            var buf: [2]Semantic.Ast.Node.Index = undefined;
            const container = ast.fullContainerDecl(&buf, data[0]) orelse continue;
            const owner = ownerOf(&file, node) orelse continue;
            const wanted = file.semantic.tokenSlice(data[1]);

            for (container.ast.members) |member| {
                const member_sym = symbolDeclaredAt(&file.semantic, member) orelse continue;
                const id: SymbolId = .{ .file = file.id, .local = member_sym };
                if (!std.mem.eql(u8, project.symbol(id).name, wanted)) continue;
                try graph.addEdge(gpa, .{ .file = file.id, .local = owner }, id, node, .definite);
            }
        }
    }
}

/// Phase 30: the cross-file half of `SymbolGraph.build`'s decl-literal
/// handling. For every `.name` literal whose expected type is spelled out
/// (see `DeclLiteral.at`), resolves that type expression across `@import`
/// boundaries and aliases (`resolveTypeNode`), then looks `name` up on it
/// the same way any `container.member` hop does. Literals `SymbolGraph`
/// already resolved same-file get a duplicate edge, which is harmless.
fn buildDeclLiterals(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;
        for (0..semantic.nodes().len) |i| {
            const node: Ast.Node.Index = @enumFromInt(i);
            const literal = DeclLiteral.at(semantic, &file.owner_map, node) orelse continue;
            const owner = file.owner_map.get(node) orelse continue;
            const ty = resolveTypeNode(project, file.id, literal.type_node) orelse continue;
            const target = hop(project, ty, literal.name) orelse continue;
            try graph.addEdge(gpa, .{ .file = file.id, .local = owner }, target, node, .possible);
        }
    }
}

/// Resolves a type-position expression node (`node`, in `file_id`'s AST)
/// to the symbol it names, across `@import` boundaries: the same
/// pointer/slice/array/`?`/`!` unwrapping `InstanceType.resolveTypeExpr`
/// does same-file, then `resolveValueChain` on what's left.
fn resolveTypeNode(project: *const Project, file_id: FileId, node: Ast.Node.Index) ?SymbolId {
    const ast = &project.file(file_id).semantic.parse.ast;
    var cur = node;
    while (true) {
        if (ast.fullPtrType(cur)) |ptr| {
            cur = ptr.ast.child_type;
        } else if (ast.fullArrayType(cur)) |array| {
            cur = array.ast.elem_type;
        } else switch (ast.nodeTag(cur)) {
            .optional_type => cur = ast.nodeData(cur).node,
            .error_union => cur = ast.nodeData(cur).node_and_node[1],
            else => break,
        }
    }
    return resolveValueChain(project, file_id, cur);
}

/// If `alias` is a plain value alias (see `FieldChain.valueAliasInit`),
/// the symbol its initializer names, resolved across `@import` boundaries.
/// `const Project = zigroot.Project;` resolves to the `Project` export of
/// whatever file `zigroot` imports; `const FileId =
/// @import("FileId.zig").FileId;` to that file's `FileId`; a bare `const
/// mod = @import("mod.zig");` to `mod.zig`'s file root.
fn resolveAlias(project: *const Project, alias: SymbolId) ?SymbolId {
    const semantic = &project.file(alias.file).semantic;
    const init_node = FieldChain.valueAliasInit(semantic, alias.local, .{ .allow_call = true }) orelse return null;
    return resolveValueChain(project, alias.file, init_node);
}

/// The `@import` edge whose call node is `node` in `file_id`, if `node` is
/// a resolved file/module import.
fn importEdgeAtNode(project: *const Project, file_id: FileId, node: Ast.Node.Index) ?ImportGraph.Edge {
    for (project.import_graph.edgesFrom(file_id)) |edge| {
        if (edge.node == node) return edge;
    }
    return null;
}

/// Phase 22: `SymbolGraph.build` walks every same-file reference through
/// `FieldChain.resolveChain` itself (both the reference's own chain and, for
/// an instance-typed variable, the chain from its type), but has no
/// `Project` to finish a chain that gets stuck on a field/variable whose own
/// declared type crosses an `@import` boundary (`h.foo.bar()`, where `foo`'s
/// type is `mod.Foo`) — see `FieldChain.ChainWalk.stuck`. Mirrors that same
/// reference-walking structure, but only to find the chains that got stuck,
/// and finishes them via `addChain`'s cross-file continuation. Chains that
/// resolved without needing this are already edged by `SymbolGraph.build`;
/// redoing them here too is harmless (graphs tolerate duplicate edges).
fn buildStuckFieldChains(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            const instance_ty = InstanceType.resolve(semantic, &file.owner_map, sym_id);

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = ownerOf(&file, ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };

                const chain = FieldChain.resolveChain(semantic, semantic, &file.owner_map, sym_id, ref.node, .definite);
                if (chain.stuck != null or chain.stuck_call != null or chain.stuck_alias != null) {
                    try addChain(project, graph, gpa, owner_id, file.id, semantic, semantic, &file.owner_map, sym_id, ref.node, .definite);
                }

                if (instance_ty) |ty| {
                    const inst_chain = FieldChain.resolveChain(semantic, semantic, &file.owner_map, ty, ref.node, .possible);
                    if (inst_chain.stuck != null or inst_chain.stuck_call != null or inst_chain.stuck_alias != null) {
                        try addChain(project, graph, gpa, owner_id, file.id, semantic, semantic, &file.owner_map, ty, ref.node, .possible);
                    }
                }
            }
        }
    }
}

/// Phase 20: if `import_node` (the `@import(...)` call itself) is
/// immediately field-accessed (`@import("json.zig").Schema`, as opposed to
/// a whole-module binding like `@import("storage.zig")`), the symbol that
/// field names in the target file — `null` if `import_node` isn't
/// field-accessed this way, or the field doesn't match one of the target
/// file's exports. A binding declared this way (`const Schema =
/// @import("json.zig").Schema;`) is narrowed to that one export before it's
/// ever named locally, so every reference to the binding — whether a
/// further field hop (`Schema.Context`) or a bare use (`Schema{...}`, `fn
/// f() Schema`) — needs to resolve against *this* symbol instead of the
/// target file's root, which is what `build`'s main loop otherwise assumes
/// every binding represents.
fn aliasRoot(from_semantic: *const Semantic, import_node: Semantic.Ast.Node.Index, target_semantic: *const Semantic, target_owner_map: *const OwnerMap) ?Semantic.Symbol.Id {
    const field_name = FieldChain.fieldAccessName(from_semantic, import_node) orelse return null;
    return FieldChain.findExport(target_semantic, target_owner_map, FILE_ROOT_SYMBOL, field_name);
}

/// Phase 15: `var s: storage.Widget = ...; s.run();`, where `storage` is an
/// `@import` binding — `InstanceType.resolve` only resolves a type
/// expression that stays within one file, so `s`'s declared type
/// (`storage.Widget`) is invisible to it. For every variable that's true
/// of, `InstanceType.crossFileRoot` hands back the unresolved `(base,
/// field)` pair; `importTarget` checks whether `base` really is one of this
/// file's `@import` bindings (same "nearest enclosing declaration of the
/// `@import(...)` call" trick the main loop above uses), and if so,
/// `FieldChain.findExport` matches `field` against the target file's
/// exports, same as `storage.foo` resolves above. Once the type itself
/// resolves, every reference to the variable used as a field access
/// (`s.run()`) chains into the target file via `FieldChain.resolveChain`,
/// same as the same-file case in `SymbolGraph`.
///
/// Phase 30: any declared type `InstanceType.resolve` couldn't finish
/// same-file goes through `declaredType`, which also follows aliases and
/// multi-hop `@import` chains (`x: *const Project`, `Project` being an
/// `@import` binding, so the type *is* the target file), not only the
/// one-hop `storage.Widget` shape.
fn buildInstanceTypes(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            if (InstanceType.resolve(semantic, &file.owner_map, sym_id) != null) continue;
            const ty = declaredType(project, .{ .file = file.id, .local = sym_id }) orelse continue;
            const target_file = project.file(ty.file);
            const target_semantic = &target_file.semantic;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = ownerOf(&file, ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };
                try addChain(project, graph, gpa, owner_id, ty.file, semantic, target_semantic, &target_file.owner_map, ty.local, ref.node, .possible);
            }
        }
    }
}

/// One of `file_id`'s `@import` edges whose binding symbol is `base`, if
/// any.
fn importEdge(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?ImportGraph.Edge {
    for (project.import_graph.edgesFrom(file_id)) |edge| {
        const binding = project.file(edge.from).owner_map.get(edge.node) orelse continue;
        if (binding == base) return edge;
    }
    return null;
}

/// `importTarget`'s target file plus, if `base` is an alias binding
/// narrowed to one export (see `aliasRoot`), that export — otherwise the
/// target file's own root. The container every `base.field` hop into the
/// target file should resolve against.
fn importTargetRoot(project: *const Project, file_id: FileId, base: Semantic.Symbol.Id) ?struct { file: FileId, root: Semantic.Symbol.Id } {
    const edge = importEdge(project, file_id, base) orelse return null;
    const target_file = project.file(edge.to);
    const from_semantic = &project.file(file_id).semantic;
    const root = aliasRoot(from_semantic, edge.node, &target_file.semantic, &target_file.owner_map) orelse FILE_ROOT_SYMBOL;
    return .{ .file = edge.to, .root = root };
}

/// Phase 17: `var s = Foo.init(...); s.run();`, where `Foo.init` (or its
/// return type) may itself cross one or more `@import` boundaries — a
/// bigger hammer than `buildInstanceTypes`' `InstanceType.crossFileRoot`,
/// which only unwinds one hop, since `Foo.init`'s callee expression and its
/// return-type expression are each resolved independently via
/// `resolveValueChain`.
///
/// For every variable whose initializer is a call expression
/// (`InstanceType.callInit`) and that isn't already resolved by the
/// annotation/struct-literal shapes (`InstanceType.resolve` — same-file —
/// or `InstanceType.crossFileRoot` — one cross-file hop): resolve the
/// callee to a function symbol, read that function's own declared return
/// type (unwrapping one `!error_union` and/or `?optional_type` layer),
/// resolve that expression too, then chain the variable's own references
/// into it the same way `buildInstanceTypes` does once its type is known.
///
/// Phase 19: a generic type-returning function (`fn Walker(comptime V: type)
/// type { return struct { ... }; }`) declares its return type as the bare
/// `type` keyword, not an expression `resolveValueChain` can resolve —
/// there's no name to chase, since the returned type is the anonymous
/// `struct { ... }` literal itself. ZLint's builder attributes that struct's
/// `pub` members as exports of whatever container the *function itself* is
/// declared in (it never pushes the anonymous struct as its own container —
/// see `FieldChain.containerOf`'s doc comment), rather than of the function
/// symbol — so `LintWalker.init` in `const LintWalker = walk.Walker(V); ...
/// LintWalker.init(...)` resolves by treating `LintWalker` as an alias for
/// `Walker`'s own enclosing container (usually `walk.zig`'s file root), the
/// same way `FieldChain.findExport` already resolves a `const Self =
/// @This();` alias to its container.
///
/// Phase 25: `for (seq) |x|` where `seq` is itself one of the above
/// call-init shapes (`const tail = tailOf(...); for (tail) |*e| { ... }`)
/// has no type-position node of its own for `InstanceType.forElementSource`
/// to chain-walk from — `seq`'s element type is only known transitively,
/// from `seq`'s own call-return type. `callInstanceType` falls back to
/// `InstanceType.forElementSequenceSymbol` and recurses into `seq`'s own
/// `callInstanceType` when the direct annotation/struct-literal/call-init
/// shapes all come back empty for the payload symbol itself.
fn buildCallInstanceTypes(gpa: Allocator, graph: *SymbolGraph, project: *const Project) Allocator.Error!void {
    for (project.files.items) |file| {
        const semantic = &file.semantic;

        var sym_it = semantic.symbols.iter();
        while (sym_it.next()) |sym_id| {
            const ty = callInstanceType(project, file.id, sym_id) orelse continue;
            const ty_file = project.file(ty.file);
            const ty_semantic = &ty_file.semantic;

            var ref_it = semantic.symbols.iterReferences(sym_id);
            while (ref_it.next()) |ref| {
                const owner = ownerOf(&file, ref.node) orelse continue;
                const owner_id: SymbolId = .{ .file = file.id, .local = owner };
                try addChain(project, graph, gpa, owner_id, ty.file, semantic, ty_semantic, &ty_file.owner_map, ty.local, ref.node, .possible);
            }
        }
    }
}

/// `sym_id`'s type, resolved the way `buildCallInstanceTypes`' doc comment
/// describes, if `sym_id` is declared `var s = Foo.init(...)` (or a
/// generic-type-returning-function equivalent) and isn't already resolved
/// by the cheaper annotation/struct-literal shapes. Exposed for `Roots`'
/// `.test`-root case, which needs the same answer per-symbol rather than
/// graph edges built from it.
///
/// Phase 29: `const s = try allocator.create(Foo);` is resolved directly
/// from `InstanceType.allocatorCreateTypeArg`'s argument-position type node
/// — `Foo`'s own `resolveValueChain`, no callee/return-type chase needed,
/// since `Foo` is already the type in question rather than something whose
/// return type must be read.
pub fn callInstanceType(project: *const Project, file_id: FileId, sym_id: Semantic.Symbol.Id) ?SymbolId {
    const file = project.file(file_id);
    const semantic = &file.semantic;

    if (InstanceType.resolve(semantic, &file.owner_map, sym_id) != null) return null;
    if (InstanceType.crossFileRoot(semantic, &file.owner_map, sym_id) != null) return null;
    if (InstanceType.allocatorCreateTypeArg(semantic, sym_id)) |type_arg| {
        return resolveValueChain(project, file_id, type_arg);
    }
    const fn_expr = InstanceType.callInit(semantic, sym_id) orelse {
        if (InstanceType.payloadCondCall(semantic, sym_id)) |callee| {
            if (resolveValueChain(project, file_id, callee)) |callee_sym| {
                if (resolveFnReturnType(project, callee_sym)) |ty| return ty;
            }
        }
        if (InstanceType.forElementSequenceSymbol(semantic, sym_id)) |seq_sym| {
            return callInstanceType(project, file_id, seq_sym);
        }
        return initChainType(project, file_id, sym_id);
    };

    const fn_sym = resolveValueChain(project, file_id, fn_expr) orelse return initChainType(project, file_id, sym_id);
    return resolveFnReturnType(project, fn_sym) orelse initChainType(project, file_id, sym_id);
}

/// Phase 30: `const semantic = &project.file(file_id).semantic;` — a
/// variable with no annotation, initialized from a value chain that mixes
/// calls, `.field` hops and wrappers across `@import` boundaries. The
/// chain lands on some declaration (`File.semantic`, a field); the
/// variable's type is that declaration's own declared type (or, for a call
/// at the end, the callee's return type, which `resolveValueChain` already
/// yields). `null` if the initializer isn't such a chain or any hop fails.
fn initChainType(project: *const Project, file_id: FileId, sym_id: Semantic.Symbol.Id) ?SymbolId {
    const semantic = &project.file(file_id).semantic;
    // A call-free chain is a plain alias: `resolveAlias` (via
    // `FieldChain`'s `stuck_alias`) already handles those.
    if (FieldChain.valueAliasInit(semantic, sym_id, .{}) != null) return null;
    const init_node = FieldChain.valueAliasInit(semantic, sym_id, .{ .allow_call = true }) orelse return null;
    const landed = resolveValueChain(project, file_id, init_node) orelse return null;
    if (declaredType(project, landed)) |ty| return ty;
    const landed_symbol = project.file(landed.file).semantic.symbols.get(landed.local);
    if (landed_symbol.flags.s_fn or landed_symbol.flags.s_member or landed_symbol.flags.s_fn_param) return null;
    return landed;
}

/// Phase 44: `log_lookup_fn: ?*const fn (ctx: ?*anyopaque, id: u8) ?*Log`
/// called as `f(ctx, id)`, where `f` came from `if (self.log_lookup_fn) |f|`.
/// The callee is a field, not a declaration with a body, so there is no `fn`
/// symbol to read a return type off — the return type is written inline in
/// the field's own annotation. Walk back to the field the way Phase 35 walks
/// back to any capture's source, then read the proto there.
fn fnPointerReturnType(project: *const Project, sym: SymbolId, depth: usize) ?SymbolId {
    if (protoReturnType(project, sym)) |ty| return ty;
    if (depth > max_hop_depth) return null;

    const semantic = &project.file(sym.file).semantic;
    const chain_base = InstanceType.chainSourceBase(semantic, sym.local) orelse return null;
    const start: SymbolId = .{ .file = sym.file, .local = chain_base.sym };
    const landing = chainLanding(project, start, chain_base.node, depth) orelse return null;

    if (landing.sym.eql(start) or landing.sym.eql(sym)) return null;
    return fnPointerReturnType(project, landing.sym, depth + 1);
}

/// The type `sym`'s own annotation names as its return, if that annotation
/// is a function pointer. The `?*const` a nullable callback field always
/// carries is unwrapped first.
fn protoReturnType(project: *const Project, sym: SymbolId) ?SymbolId {
    const semantic = &project.file(sym.file).semantic;
    const ast = &semantic.parse.ast;

    for (InstanceType.declaredTypeNodes(semantic, sym.local).slice()) |type_node| {
        var cur = type_node;
        while (true) {
            if (ast.fullPtrType(cur)) |ptr| {
                cur = ptr.ast.child_type;
            } else if (ast.nodeTag(cur) == .optional_type) {
                cur = ast.nodeData(cur).node;
            } else {
                break;
            }
        }

        var proto_buf: [1]Ast.Node.Index = undefined;
        const proto = ast.fullFnProto(&proto_buf, cur) orelse continue;
        const return_node = proto.ast.return_type.unwrap() orelse continue;
        if (resolveTypeNode(project, sym.file, return_node)) |ty| return ty;
    }
    return null;
}

/// `fn_sym`'s declared return type, resolved across as many `@import`
/// boundaries as needed — the shared tail of `callInstanceType` (a call-init
/// variable's callee) and `addChain`'s `stuck_call` handling (a call used
/// directly as a field-access base, Phase 27). `null` if `fn_sym` isn't a
/// function, or its declared return type doesn't resolve.
fn resolveFnReturnType(project: *const Project, fn_sym: SymbolId) ?SymbolId {
    const fn_semantic = &project.file(fn_sym.file).semantic;
    const fn_symbol = fn_semantic.symbols.get(fn_sym.local);
    if (!fn_symbol.flags.s_fn) {
        if (fnPointerReturnType(project, fn_sym, 0)) |ty| return ty;

        // Calling something that isn't a function: a generic container
        // reached through an alias (`const Mixin = util.Bitflags;
        // Mixin(Flags)`) — unwrap the alias and retry once.
        const aliased = resolveAlias(project, fn_sym) orelse return null;
        if (aliased.eql(fn_sym)) return null;
        if (!project.file(aliased.file).semantic.symbols.get(aliased.local).flags.s_fn) return null;
        return resolveFnReturnType(project, aliased);
    }

    const fn_ast = &fn_semantic.parse.ast;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = fn_ast.fullFnProto(&proto_buf, fn_symbol.decl) orelse return null;
    var return_node = proto.ast.return_type.unwrap() orelse return null;
    if (fn_ast.nodeTag(return_node) == .error_union) {
        return_node = fn_ast.nodeData(return_node).node_and_node[1];
    }
    if (fn_ast.nodeTag(return_node) == .optional_type) {
        return_node = fn_ast.nodeData(return_node).node;
    }
    if (fn_ast.fullPtrType(return_node)) |ptr| {
        return_node = ptr.ast.child_type;
    }

    if (isTypeKeyword(fn_semantic, return_node)) {
        const fn_owner_map = &project.file(fn_sym.file).owner_map;
        const container = FieldChain.containerOf(fn_semantic, fn_owner_map, fn_sym.local) orelse return null;
        return .{ .file = fn_sym.file, .local = container };
    }
    return resolveTypeNode(project, fn_sym.file, return_node);
}

/// Phase 47: two `build.zig` files in one project can register the same
/// module name for different files — `apps/iamd` and `apps/clusterd` both
/// call theirs "scheduler". `Project` keeps every candidate and edges the
/// one `@import` node to all of them, so taking the first silently lands in
/// the wrong file and every hop off it fails. The field being hopped is what
/// disambiguates: only one candidate declares it.
fn hopThroughImport(project: *const Project, file_id: FileId, import_node: Ast.Node.Index, field: []const u8) ?SymbolId {
    for (project.import_graph.edgesFrom(file_id)) |edge| {
        if (edge.node != import_node) continue;
        if (hop(project, .{ .file = edge.to, .local = FILE_ROOT_SYMBOL }, field)) |target| return target;
    }
    return null;
}

/// The `@import(...)` call node `node` names, either directly or through a
/// one-step binding (`const scheduler_mod = @import("scheduler");`). `null`
/// if `node` isn't an import in either shape.
fn importCallSite(project: *const Project, file_id: FileId, node: Ast.Node.Index) ?Ast.Node.Index {
    const semantic = &project.file(file_id).semantic;
    if (isImportCall(semantic, node)) return node;

    if (semantic.parse.ast.nodeTag(node) != .identifier) return null;
    const sym = InstanceType.referenceAt(semantic, node) orelse return null;
    const init_node = FieldChain.valueAliasInit(semantic, sym, .{}) orelse return null;
    if (!isImportCall(semantic, init_node)) return null;
    return init_node;
}

/// Whether `node` is an `@import(...)` builtin call.
fn isImportCall(semantic: *const Semantic, node: Ast.Node.Index) bool {
    const ast = &semantic.parse.ast;
    return switch (ast.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, semantic.tokenSlice(ast.nodeMainToken(node)), "@import"),
        else => false,
    };
}

/// Whether `node` is the bare `type` keyword — the return-type spelling of a
/// generic type-returning function (`fn Walker(comptime V: type) type { ...
/// }`), as opposed to a value's own type. ZLint parses it as a plain
/// identifier, so this just checks the token text.
fn isTypeKeyword(semantic: *const Semantic, node: Ast.Node.Index) bool {
    const ast = &semantic.parse.ast;
    return ast.nodeTag(node) == .identifier and std.mem.eql(u8, semantic.tokenSlice(ast.nodeMainToken(node)), "type");
}

/// Resolves a value-position expression node (`node`, in `file_id`'s AST) —
/// a bare identifier, or a chain of `.field` accesses off one — to the
/// symbol it names, crossing as many `@import` boundaries as the chain
/// does (see the module doc comment). `null` if `node` isn't that shape, or
/// any hop doesn't resolve.
fn resolveValueChain(project: *const Project, file_id: FileId, node: Ast.Node.Index) ?SymbolId {
    const semantic = &project.file(file_id).semantic;
    const ast = &semantic.parse.ast;

    return switch (ast.nodeTag(node)) {
        .identifier => blk: {
            const sym = InstanceType.referenceAt(semantic, node) orelse break :blk null;
            break :blk .{ .file = file_id, .local = sym };
        },
        .field_access => blk: {
            const data = ast.nodeData(node).node_and_token;
            const field = semantic.tokenSlice(data[1]);
            if (importCallSite(project, file_id, data[0])) |import_node| {
                break :blk hopThroughImport(project, file_id, import_node, field);
            }
            const base = resolveValueChain(project, file_id, data[0]) orelse break :blk null;
            break :blk hop(project, base, field);
        },
        // A bare `@import("x.zig")` in value position names the target
        // file's root — the whole file as a container.
        .builtin_call_two, .builtin_call_two_comma => blk: {
            if (!std.mem.eql(u8, semantic.tokenSlice(ast.nodeMainToken(node)), "@import")) break :blk null;
            const edge = importEdgeAtNode(project, file_id, node) orelse break :blk null;
            break :blk .{ .file = edge.to, .local = FILE_ROOT_SYMBOL };
        },
        // Wrappers that don't change what the value names.
        .address_of, .@"try", .deref => resolveValueChain(project, file_id, ast.nodeData(node).node),
        .grouped_expression, .unwrap_optional => resolveValueChain(project, file_id, ast.nodeData(node).node_and_token[0]),
        // A call names an instance of the callee's declared return type
        // (or, for a `type`-returning generic, the container it returns).
        .call, .call_comma, .call_one, .call_one_comma => blk: {
            var buf: [1]Ast.Node.Index = undefined;
            const call = ast.fullCall(&buf, node) orelse break :blk null;
            const callee = resolveValueChain(project, file_id, call.ast.fn_expr) orelse break :blk null;
            break :blk resolveFnReturnType(project, callee);
        },
        else => null,
    };
}

/// `base.field`: matched against `base`'s own file's exports first (via
/// `FieldChain.findExport`, which already unwraps a `@This()` alias `base`
/// might be), then — if `base` is itself bound to an `@import` (a
/// re-export) — against the target file's exports instead.
///
/// Issue 10: if neither matches, `base` isn't a container/import binding
/// itself but a field or variable whose own *declared type* is — the
/// `state.channels.get_or_open()` shape, where `channels: table.ChannelTable`
/// is a container field. `declaredType` resolves that type (same-file or
/// across the `@import` boundary it's declared with, same as
/// `FieldChain.resolveChain`'s in-chain redirection does for a stuck hop —
/// see `addChain`), and the hop is retried against it.
///
/// Phase 30: a `base` that's a plain value alias (`const Project =
/// zigroot.Project;`) is unwrapped through `resolveAlias` and the hop
/// retried on what it names. Alias chains are bounded (`max_hop_depth`) so
/// a cyclic `const a = b; const b = a;` can't recurse forever.
fn hop(project: *const Project, base: SymbolId, field: []const u8) ?SymbolId {
    return hopDepth(project, base, field, 0);
}

const max_hop_depth = 16;

fn hopDepth(project: *const Project, base: SymbolId, field: []const u8, depth: usize) ?SymbolId {
    if (depth > max_hop_depth) return null;
    const base_file = project.file(base.file);
    if (FieldChain.findExport(&base_file.semantic, &base_file.owner_map, base.local, field)) |found| {
        return .{ .file = base.file, .local = found };
    }

    if (importTargetRoot(project, base.file, base.local)) |target| {
        const target_file = project.file(target.file);
        if (FieldChain.findExport(&target_file.semantic, &target_file.owner_map, target.root, field)) |found| {
            return .{ .file = target.file, .local = found };
        }
    }

    if (resolveAlias(project, base)) |aliased| {
        if (!aliased.eql(base)) return hopDepth(project, aliased, field, depth + 1);
    }

    const ty = declaredType(project, base) orelse return null;
    return hopDepth(project, ty, field, depth + 1);
}

/// `base`'s own declared type, resolved same-file via `InstanceType.resolve`
/// or, if the type expression itself crosses an `@import` boundary
/// (`InstanceType.crossFileRoot`), by resolving that boundary the same way
/// `importTargetRoot` + `FieldChain.findExport` already do for a binding's
/// own field hops above. `null` if `base` has no syntactically-resolvable
/// declared type.
///
/// Phase 30: failing both, every declared-type node `InstanceType` knows
/// how to find (`declaredTypeNodes`) is resolved through `resolveTypeNode`
/// instead — which follows aliases and any number of `@import` hops, so
/// `owner: []Symbol.Id.Optional` (with `Symbol` itself an alias of an
/// import's export) resolves where the one-hop `crossFileRoot` can't.
fn declaredType(project: *const Project, base: SymbolId) ?SymbolId {
    return declaredTypeDepth(project, base, 0);
}

fn declaredTypeDepth(project: *const Project, base: SymbolId, depth: usize) ?SymbolId {
    if (depth > max_hop_depth) return null;

    const base_file = project.file(base.file);
    const semantic = &base_file.semantic;
    const owner_map = &base_file.owner_map;

    if (InstanceType.resolve(semantic, owner_map, base.local)) |ty| {
        return .{ .file = base.file, .local = ty };
    }

    // Before `crossFileRoot`: that shortcut resolves one hop off whichever
    // symbol the same-file walk stalled on, which for `&state.conns[i]` is
    // `state` — handing back `State` and dropping the field and index hops
    // that were the whole point. Walking the chain resolves them.
    if (chainSourceType(project, base, depth)) |ty| return ty;

    if (InstanceType.crossFileRoot(semantic, owner_map, base.local)) |root| {
        if (importTargetRoot(project, base.file, root.base)) |target| {
            const target_file = project.file(target.file);
            if (FieldChain.findExport(&target_file.semantic, &target_file.owner_map, target.root, root.field)) |ty| {
                return .{ .file = target.file, .local = ty };
            }
        }
    }

    for (InstanceType.declaredTypeNodes(semantic, base.local).slice()) |type_node| {
        if (resolveTypeNode(project, base.file, type_node)) |ty| return ty;
    }

    if (branchInitType(project, base, depth)) |ty| return ty;

    // Phase 42: last, because it is the most speculative — `const gz =
    // compressGzip(...) catch null;` has no type written anywhere, only a
    // callee whose declared return type has to be chased across files.
    return callInstanceType(project, base.file, base.local);
}

/// Phase 48: `const pool = if (tag.pool_id == SA_POOL_ID) pools.sa else
/// pools.login;` — a variable whose initializer is an `if` expression has its
/// type in the branches and nowhere else. Both branches have to agree for the
/// program to compile, so the first one that resolves is the answer.
fn branchInitType(project: *const Project, base: SymbolId, depth: usize) ?SymbolId {
    const semantic = &project.file(base.file).semantic;
    const symbol = semantic.symbols.get(base.local);
    if (!symbol.flags.s_variable) return null;

    const ast = &semantic.parse.ast;
    const decl = ast.fullVarDecl(symbol.decl) orelse return null;
    if (decl.ast.type_node.unwrap() != null) return null;
    const init_node = decl.ast.init_node.unwrap() orelse return null;

    const if_full = ast.fullIf(init_node) orelse return null;
    const else_expr = if_full.ast.else_expr.unwrap() orelse if_full.ast.then_expr;
    for ([_]Ast.Node.Index{ if_full.ast.then_expr, else_expr }) |branch| {
        const landed = resolveValueChain(project, base.file, branch) orelse continue;
        if (landed.eql(base)) continue;
        if (declaredTypeDepth(project, landed, depth + 1)) |ty| return ty;
    }
    return null;
}

/// Phase 35: `if (self.spoa) |sp| sp.onAccept(res);` written in a file that
/// doesn't declare `self`'s own struct — the split-implementation shape,
/// where `HttpServer` lives in `Http.zig` and its io_uring completion arms
/// live in `http_loop.zig`. `InstanceType.chainSourceBase` hands back the
/// unwalked condition chain (`self`, at its identifier node); walking it
/// with a `Project` behind it lands on `HttpServer.spoa`, whose own declared
/// type (`?*spoa.SpoaServer`) is another cross-`@import` hop the recursion
/// then resolves. Without this the whole `SpoaServer`/`LocalSocketServer`
/// method set reads as unreachable, since nothing else names those methods.
///
/// The same base covers `for` payloads and `const srv = self.srv;`, which
/// stall on exactly the same first hop for exactly the same reason.
fn chainSourceType(project: *const Project, base: SymbolId, depth: usize) ?SymbolId {
    const semantic = &project.file(base.file).semantic;
    const chain_base = InstanceType.chainSourceBase(semantic, base.local) orelse return null;
    const start: SymbolId = .{ .file = base.file, .local = chain_base.sym };
    const landing = chainLanding(project, start, chain_base.node, depth) orelse return null;
    const landed = landing.sym;

    // A chain that lands back on `base` itself has learned nothing, and
    // recursing into it would not terminate. Landing back on `start` is
    // different: `if (gz) |*g|` has no hops to walk, so `g`'s type is
    // whatever `gz`'s own is — reading it costs one more depth step, which
    // `max_hop_depth` already bounds.
    if (landed.eql(base)) return null;
    if (chain_base.landing_is_type or landing.is_type) return landed;
    return declaredTypeDepth(project, landed, depth + 1);
}

/// Where the `.field` chain from `start` (referenced at `start_node`, a node
/// in `start`'s own file) lands, following the same alias / declared-type /
/// call-return-type hops `addChain` does but recording no edges — a caller
/// resolving a *type* needs the landing symbol itself, not a graph
/// contribution. `null` if the walk stops on a runtime-named `@field(...)`
/// hop, whose landing is by definition not a single symbol.
/// Phase 41: every symbol the `.field` chain from `start` (referenced at
/// `start_node`) passes through or lands on, appended to `out`, resolved
/// across `@import` boundaries the same way `addChain` does but recording no
/// edges. A reference written straight inside a container-level `test { ...
/// }` or `comptime { ... }` block has no owning declaration, so no graph edge
/// ever carries it — `Roots` has to seed what such a block reaches, and
/// seeding only the base symbol stops at the first hop `FieldChain` can't
/// finish alone (`var pool = StringPool.init(...); pool.unmintFrom(...)`,
/// where `pool`'s type comes from a call return).
pub fn chainTargets(
    gpa: Allocator,
    project: *const Project,
    start: SymbolId,
    start_node: Semantic.Ast.Node.Index,
    out: *std.ArrayListUnmanaged(SymbolId),
) Allocator.Error!void {
    const ast = &project.file(start.file).semantic;
    var cur = start;
    var node = start_node;
    var kind: FieldChain.Kind = .definite;

    var hops: usize = 0;
    while (hops <= max_hop_depth) : (hops += 1) {
        const cur_file = project.file(cur.file);
        const chain = FieldChain.resolveChain(ast, &cur_file.semantic, &cur_file.owner_map, cur.local, node, kind);

        for (chain.visitedSlice()) |through| {
            try out.append(gpa, .{ .file = cur.file, .local = through });
        }
        try out.append(gpa, .{ .file = cur.file, .local = chain.result.symbol });
        if (chain.unknown) |unknown| for (unknown.exports) |target| {
            try out.append(gpa, .{ .file = cur.file, .local = target });
        };

        const step = chainStep(project, ast, cur.file, &chain, 0) orelse return;
        try out.append(gpa, step.next);
        cur = step.next;
        node = step.node;
        kind = step.kind;
    }
}

fn chainLanding(project: *const Project, start: SymbolId, start_node: Semantic.Ast.Node.Index, depth: usize) ?Landing {
    const ast = &project.file(start.file).semantic;
    var cur = start;
    var node = start_node;
    var kind: FieldChain.Kind = .definite;
    var stepped_to_type = false;

    var hops: usize = 0;
    while (hops <= max_hop_depth) : (hops += 1) {
        const cur_file = project.file(cur.file);
        const chain = FieldChain.resolveChain(ast, &cur_file.semantic, &cur_file.owner_map, cur.local, node, kind);
        if (chain.unknown != null) return null;

        const landed: SymbolId = .{ .file = cur.file, .local = chain.result.symbol };
        const step = chainStep(project, ast, cur.file, &chain, depth) orelse {
            // A step that already yielded the type only counts if the walk
            // stopped right there; a further hop off it lands on a member
            // whose own declared type is the answer instead.
            return .{ .sym = landed, .is_type = stepped_to_type and landed.eql(cur) };
        };
        cur = step.next;
        node = step.node;
        kind = step.kind;
        stepped_to_type = step.is_type;
    }
    return null;
}

/// Where a chain walk stopped, and whether that symbol *is* the type or is a
/// declaration whose own type still has to be read (see `ChainBase`).
const Landing = struct {
    sym: SymbolId,
    is_type: bool,
};

/// Phase 52: `redirect_uri_pending: std.ArrayListUnmanaged(RedirectUriRequest)`
/// iterated as `for (self.redirect_uri_pending.items) |*existing|`. The
/// container type comes from a module this project never analyzes, so there is
/// no `items` to find and no return type to read — but the element type is
/// written right there in the instantiation, as its first resolvable type
/// argument. Only an `items` hop is matched: that is the one field name whose
/// meaning is fixed across std's list types.
fn genericElement(project: *const Project, ast: *const Semantic, base: SymbolId, node: Semantic.Ast.Node.Index) ?SymbolId {
    // `node` indexes the AST the walk started in, which is not `base`'s file
    // once the chain has crossed an `@import`.
    const name = FieldChain.fieldAccessName(ast, node) orelse return null;
    if (!std.mem.eql(u8, name, "items")) return null;

    const semantic = &project.file(base.file).semantic;
    const base_ast = &semantic.parse.ast;
    for (InstanceType.declaredTypeNodes(semantic, base.local).slice()) |type_node| {
        var buf: [1]Ast.Node.Index = undefined;
        const call = base_ast.fullCall(&buf, type_node) orelse continue;
        for (call.ast.params) |param| {
            const ty = resolveTypeNode(project, base.file, param) orelse continue;
            // The argument is usually spelled through a local alias
            // (`const Req = types.Req;`), which has no members of its own.
            return aliasTarget(project, ty);
        }
    }
    return null;
}

/// Phase 53: the member named by the `.field` hop at `node` (a node in
/// `ast`), when `base`'s own declared type is an anonymous container spelled
/// inline — `body: union(enum) { memory: struct { buf: [N]u8, len: usize,
/// pub fn slice(...) ... } }`. There is no symbol standing for that type, so
/// the hop is matched against its member list directly, the way Phase 43
/// matches an anonymous return type's.
fn anonymousTypeMember(project: *const Project, ast: *const Semantic, base: SymbolId, node: Semantic.Ast.Node.Index) ?SymbolId {
    const field = FieldChain.fieldAccessName(ast, node) orelse return null;

    const semantic = &project.file(base.file).semantic;
    const base_ast = &semantic.parse.ast;
    for (InstanceType.declaredTypeNodes(semantic, base.local).slice()) |type_node| {
        var buf: [2]Ast.Node.Index = undefined;
        const container = base_ast.fullContainerDecl(&buf, type_node) orelse continue;
        for (container.ast.members) |member| {
            const member_sym = symbolDeclaredAt(semantic, member) orelse continue;
            const member_id: SymbolId = .{ .file = base.file, .local = member_sym };
            if (std.mem.eql(u8, project.symbol(member_id).name, field)) return member_id;
        }
    }
    return null;
}

/// Follows `resolveAlias` to the end, bounded like every other hop loop.
fn aliasTarget(project: *const Project, start: SymbolId) SymbolId {
    var cur = start;
    var hops: usize = 0;
    while (hops <= max_hop_depth) : (hops += 1) {
        const next = resolveAlias(project, cur) orelse return cur;
        if (next.eql(cur)) return cur;
        cur = next;
    }
    return cur;
}

const ChainStep = struct {
    /// Whether `next` is the type itself rather than a declaration whose
    /// type still has to be read — true only for the generic-element step,
    /// which reads a type argument straight out of an instantiation.
    is_type: bool = false,
    next: SymbolId,
    node: Semantic.Ast.Node.Index,
    kind: FieldChain.Kind,
};

/// The next symbol `chainLanding` should resume its walk from, for a chain
/// that got stuck on an alias, a cross-file declared type, or a call return
/// type. `null` when the chain isn't stuck (it's finished) or the stuck hop
/// itself doesn't resolve (it's as finished as it will get) — `chainLanding`
/// treats both the same way, by returning where the walk stopped.
fn chainStep(project: *const Project, ast: *const Semantic, cur_file: FileId, chain: *const FieldChain.ChainWalk, depth: usize) ?ChainStep {
    if (chain.stuck_alias) |stuck| {
        const aliased = resolveAlias(project, .{ .file = cur_file, .local = stuck.symbol }) orelse return null;
        if (aliased.file == cur_file and aliased.local == stuck.symbol) return null;
        return .{ .next = aliased, .node = stuck.node, .kind = stuck.kind };
    }
    if (chain.stuck) |stuck| {
        const stuck_id: SymbolId = .{ .file = cur_file, .local = stuck.symbol };
        if (declaredTypeDepth(project, stuck_id, depth + 1)) |ty| {
            return .{ .next = ty, .node = stuck.node, .kind = stuck.kind };
        }
        const element = genericElement(project, ast, stuck_id, stuck.node) orelse return null;
        return .{ .next = element, .node = stuck.node, .kind = .possible, .is_type = true };
    }
    if (chain.stuck_call) |stuck_call| {
        const ty = resolveFnReturnType(project, .{ .file = cur_file, .local = stuck_call.fn_symbol }) orelse return null;
        return .{ .next = ty, .node = stuck_call.call_node, .kind = stuck_call.kind };
    }
    return null;
}

/// Continues resolving `start` (declared in `symbols`, first referenced at
/// `start_node` in `ast`) via `FieldChain.resolveChain` at `start_kind`
/// confidence, adding an edge to wherever the chain ends up, plus `.unknown`
/// edges to every export if it stopped at a runtime-named `@field(...)` hop.
///
/// Phase 22: if the walk gets stuck on a field/variable whose own declared
/// type crosses another `@import` boundary (`h.foo.bar()`, where `foo`'s
/// type is `mod.Foo`) — the same shape `buildInstanceTypes` resolves for a
/// chain's *starting* symbol, just reached mid-chain instead — resolves that
/// hop the same way (`InstanceType.crossFileRoot` + `importTargetRoot` +
/// `FieldChain.findExport`) and resumes the walk in the target file. Loops
/// since the newly-resolved type can itself have a field with yet another
/// cross-file type.
fn addChain(
    project: *const Project,
    graph: *SymbolGraph,
    gpa: Allocator,
    owner_id: SymbolId,
    target_file: FileId,
    ast: *const Semantic,
    symbols: *const Semantic,
    owner_map: *const OwnerMap,
    start: Semantic.Symbol.Id,
    start_node: Semantic.Ast.Node.Index,
    start_kind: FieldChain.Kind,
) !void {
    var cur_file = target_file;
    var cur_symbols = symbols;
    var cur_owner_map = owner_map;
    var chain = FieldChain.resolveChain(ast, cur_symbols, cur_owner_map, start, start_node, start_kind);

    var alias_hops: usize = 0;
    while (true) {
        // Every symbol a segment passed through is as used as its end.
        for (chain.visitedSlice()) |through| {
            try graph.addEdge(gpa, owner_id, .{ .file = cur_file, .local = through }, start_node, .possible);
        }

        if (chain.stuck_alias) |stuck| {
            // Phase 30: resume from whatever the alias names, which may be
            // another alias (a re-export chain), so this loops; bounded
            // for the same reason `hop` is.
            alias_hops += 1;
            if (alias_hops > max_hop_depth) break;
            const aliased = resolveAlias(project, .{ .file = cur_file, .local = stuck.symbol }) orelse break;
            if (aliased.file == cur_file and aliased.local == stuck.symbol) break;
            const next_file = project.file(aliased.file);

            // The alias target is passed through too (and, for an
            // `@import` binding, it's the target file's root — reaching it
            // reaches the file's top-level fields).
            try graph.addEdge(gpa, owner_id, aliased, start_node, .possible);

            cur_file = aliased.file;
            cur_symbols = &next_file.semantic;
            cur_owner_map = &next_file.owner_map;
            chain = FieldChain.resolveChain(ast, cur_symbols, cur_owner_map, aliased.local, stuck.node, stuck.kind);
            continue;
        }

        if (chain.stuck) |stuck| {
            const stuck_id: SymbolId = .{ .file = cur_file, .local = stuck.symbol };
            const ty = declaredType(project, stuck_id) orelse {
                // Phase 53: the hop's container is an anonymous type written
                // inline (`memory: struct { ..., pub fn slice(...) }`), which
                // has no symbol to resolve to. Match the hop's name against
                // its members, then resume past the hop.
                const member = anonymousTypeMember(project, ast, stuck_id, stuck.node) orelse break;
                const member_file = project.file(member.file);
                const past_hop = ast.node_links.getParent(stuck.node) orelse break;

                try graph.addEdge(gpa, owner_id, member, start_node, .definite);

                cur_file = member.file;
                cur_symbols = &member_file.semantic;
                cur_owner_map = &member_file.owner_map;
                chain = FieldChain.resolveChain(ast, cur_symbols, cur_owner_map, member.local, past_hop, .possible);
                continue;
            };
            const next_file = project.file(ty.file);

            try graph.addEdge(gpa, owner_id, ty, start_node, .possible);

            cur_file = ty.file;
            cur_symbols = &next_file.semantic;
            cur_owner_map = &next_file.owner_map;
            chain = FieldChain.resolveChain(ast, cur_symbols, cur_owner_map, ty.local, stuck.node, stuck.kind);
            continue;
        }

        if (chain.stuck_call) |stuck_call| {
            const ty = resolveFnReturnType(project, .{ .file = cur_file, .local = stuck_call.fn_symbol }) orelse break;
            const ty_file = project.file(ty.file);

            try graph.addEdge(gpa, owner_id, .{ .file = cur_file, .local = stuck_call.fn_symbol }, start_node, .possible);
            try graph.addEdge(gpa, owner_id, ty, start_node, .possible);

            cur_file = ty.file;
            cur_symbols = &ty_file.semantic;
            cur_owner_map = &ty_file.owner_map;
            chain = FieldChain.resolveChain(ast, cur_symbols, cur_owner_map, ty.local, stuck_call.call_node, stuck_call.kind);
            continue;
        }

        break;
    }

    const kind: SymbolGraph.EdgeKind = switch (chain.result.kind) {
        .definite => .definite,
        .possible => .possible,
    };
    try graph.addEdge(gpa, owner_id, .{ .file = cur_file, .local = chain.result.symbol }, chain.result.node, kind);
    if (chain.unknown) |unknown| for (unknown.exports) |target| {
        try graph.addEdge(gpa, owner_id, .{ .file = cur_file, .local = target }, unknown.node, .unknown);
    };
}
