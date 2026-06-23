const std = @import("std");
const tree_module = @import("tree.zig");
const Tree = tree_module.Tree;
const Node = tree_module.Node;

/// Every float in the machine dump renders with this format: locale-independent
/// and byte-deterministic across runs (e.g. `360.0000`, `0.9200`, `0.0000`).
const FLOAT_FORMAT = "{d:.4}";

/// The three debug consumers of the shadow tree. All share the single collection
/// layer (root enumeration + pre-order walk); only the per-node line differs.
/// overlay is the Phase-13 render-overlay report: per node, its element bounds, its
/// dirty flags, and its hit rect — all read from node.layout / the flags (Ф1: the
/// hit rect IS node.layout, so the overlay names it once and never recomputes it).
const Report = enum { shadow_tree, layout_trace, overlay };

/// Dumps the shadow tree to writer. The machine form (pretty == false) is a
/// single deterministic line per node in a fixed field order, refs by id, no
/// pointer addresses, children in array order, roots enumerated by ascending id
/// (NOT hash-map order). The pretty form reuses the SAME walk and is free of the
/// byte-determinism contract. A single collection layer drives both outputs.
pub fn dump(tree: *Tree, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    try collect(tree, writer, .shadow_tree, pretty);
}

/// Dumps the layout trace covering BOTH passes (Ф9): per node, the proposed main
/// extent and reported preferred size from the measure pass, plus the available
/// main/cross space it was laid into and the emitted rect from the place pass
/// (all recomputed/read from Node fields, NOT from layout.zig or measure.zig —
/// debug imports tree only). This localizes a drifted coordinate to a node AND a
/// pass (spec §0a). Machine mode (pretty == false) is byte-deterministic; both
/// modes share the same walk.
pub fn dumpLayoutTrace(tree: *Tree, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    try collect(tree, writer, .layout_trace, pretty);
}

/// Dumps the render overlays (Ф13): per node, the element bounds, the dirty flags,
/// and the hit rect. The element bounds and the hit rect are BOTH node.layout (Ф1:
/// the hit rect IS the laid-out rect), surfaced here under the overlay names a
/// renderer would draw — element outline, dirty highlight, hit region. Reuses the
/// same collect/walk as the tree and layout dumps (the single-collection-layer
/// rule); machine mode (pretty == false) is byte-deterministic.
pub fn dumpOverlays(tree: *Tree, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    try collect(tree, writer, .overlay, pretty);
}

fn collect(tree: *Tree, writer: *std.Io.Writer, report: Report, pretty: bool) std.Io.Writer.Error!void {
    var id: u32 = 0;
    while (id < tree.next_id) : (id += 1) {
        const node = tree.lookup(id) orelse continue;
        if (node.parent == null) try walk(node, writer, report, pretty, 0);
    }
}

fn walk(node: *Node, writer: *std.Io.Writer, report: Report, pretty: bool, depth: usize) std.Io.Writer.Error!void {
    switch (report) {
        .shadow_tree => if (pretty) try writePretty(node, writer, depth) else try writeMachine(node, writer),
        .layout_trace => if (pretty) try writeTracePretty(node, writer, depth) else try writeTraceMachine(node, writer),
        .overlay => if (pretty) try writeOverlayPretty(node, writer, depth) else try writeOverlayMachine(node, writer),
    }
    for (node.children.items) |child| try walk(child, writer, report, pretty, depth + 1);
}

fn writeMachine(node: *Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("node id={d} kind={s} parent=", .{ node.id, @tagName(node.kind) });
    if (node.parent) |parent| {
        try writer.print("{d}", .{parent.id});
    } else {
        try writer.writeAll("none");
    }
    try writer.writeAll(" children=[");
    for (node.children.items, 0..) |child, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{child.id});
    }
    try writer.print("] pos=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ node.position_x, node.position_y });
    try writer.print(" size=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ node.width, node.height });
    try writer.print(" color=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ node.color_r, node.color_g, node.color_b, node.color_a });
    try writer.print(" radius=" ++ FLOAT_FORMAT, .{node.corner_radius});
    try writer.print(" layout=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
    try writer.print(" layout_dirty={} paint_dirty={}\n", .{ node.layout_dirty, node.paint_dirty });
}

fn writePretty(node: *Node, writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    var indent: usize = 0;
    while (indent < depth) : (indent += 1) try writer.writeAll("  ");
    try writer.print("{s}#{d}", .{ @tagName(node.kind), node.id });
    try writer.print(" pos=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ node.position_x, node.position_y });
    try writer.print(" size=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ node.width, node.height });
    try writer.print(" layout=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
    try writer.print(" dirty=(layout={}, paint={})\n", .{ node.layout_dirty, node.paint_dirty });
}

/// The available main/cross space a node was laid into, recomputed from Node
/// fields alone (debug must NOT import layout.zig). A child's avail is its
/// parent's content extent (parent rect minus parent padding) projected by the
/// parent's direction; a root's avail is its own laid-out box projected by its
/// own direction. Mirrors layout.zig's projection without depending on it.
const AvailableSpace = struct {
    main: f32,
    cross: f32,
};

fn availableSpace(node: *Node) AvailableSpace {
    if (node.parent) |parent| {
        const content_width = parent.layout.w - parent.padding_left - parent.padding_right;
        const content_height = parent.layout.h - parent.padding_top - parent.padding_bottom;
        return projectExtents(parent.direction, content_width, content_height);
    }
    return projectExtents(node.direction, node.layout.w, node.layout.h);
}

fn projectExtents(direction: tree_module.Direction, width: f32, height: f32) AvailableSpace {
    return switch (direction) {
        .row => .{ .main = width, .cross = height },
        .column => .{ .main = height, .cross = width },
    };
}

fn writeTraceMachine(node: *Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const avail = availableSpace(node);
    try writer.print("node id={d} proposed=" ++ FLOAT_FORMAT, .{ node.id, avail.main });
    try writer.print(" preferred=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ node.preferred.main, node.preferred.cross });
    try writer.print(" avail=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ avail.main, avail.cross });
    try writer.print(" rect=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
    try writer.print(" measure={s}", .{@tagName(node.measure_source)});
    try writer.print(" glyphs={d} shape={s}\n", .{ glyphCount(node), @tagName(node.shape_source) });
}

fn writeTracePretty(node: *Node, writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    var indent: usize = 0;
    while (indent < depth) : (indent += 1) try writer.writeAll("  ");
    const avail = availableSpace(node);
    try writer.print("#{d} proposed=" ++ FLOAT_FORMAT, .{ node.id, avail.main });
    try writer.print(" preferred=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ node.preferred.main, node.preferred.cross });
    try writer.print(" avail=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ avail.main, avail.cross });
    try writer.print(" rect=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
    try writer.print(" measure={s}", .{@tagName(node.measure_source)});
    try writer.print(" glyphs={d} shape={s}\n", .{ glyphCount(node), @tagName(node.shape_source) });
}

/// The shaped glyph count of a node for the trace marker: zero on a node the shape
/// pass has not placed glyphs on (the .unshaped default and every .view node), the
/// placed-glyph count once the shape seam crossed. Read directly from the Node
/// field so debug imports only tree.zig.
fn glyphCount(node: *Node) usize {
    return (node.placed_glyphs orelse &.{}).len;
}

/// The overlay machine line: element bounds, dirty flags, and the hit rect, all
/// per node, byte-deterministic. element= and hit= are BOTH node.layout (Ф1 — the
/// hit rect IS the laid-out rect) under the two overlay names a renderer would draw.
fn writeOverlayMachine(node: *Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("node id={d}", .{node.id});
    try writer.print(" element=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
    try writer.print(" dirty=layout={},paint={}", .{ node.layout_dirty, node.paint_dirty });
    try writer.print(" hit=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "\n", .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
}

fn writeOverlayPretty(node: *Node, writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    var indent: usize = 0;
    while (indent < depth) : (indent += 1) try writer.writeAll("  ");
    try writer.print("#{d}", .{node.id});
    try writer.print(" element=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
    try writer.print(" dirty=(layout={}, paint={})", .{ node.layout_dirty, node.paint_dirty });
    try writer.print(" hit=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")\n", .{ node.layout.x, node.layout.y, node.layout.w, node.layout.h });
}

/// Per-frame counters the render overlay and the debug agent read (Ф13). The
/// counters are byte-deterministic for a given frame; the timings are not (they
/// vary per run), so the MACHINE dump omits them — only the pretty form surfaces
/// them (deviation d: a non-deterministic field would break the byte-identical
/// machine-dump contract test). A static frame recomputes nothing, so
/// recomputed_node_count == 0 is the incrementality invariant.
pub const FrameStats = struct {
    instance_count: u32,
    draw_call_count: u32,
    recomputed_node_count: u32,
    layout_micros: u64 = 0,
    produce_micros: u64 = 0,
};

/// Dumps the frame stats. The machine form (pretty == false) emits ONLY the
/// deterministic counters (no timings) as a single line so a before/after diff is
/// byte-stable; the pretty form adds the per-run timings for a human. Both read the
/// SAME FrameStats (single collection, dual output).
pub fn dumpFrameStats(stats: FrameStats, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    try writer.print("frame instances={d} draws={d} recomputed={d}", .{ stats.instance_count, stats.draw_call_count, stats.recomputed_node_count });
    if (pretty) {
        try writer.print(" layout_us={d} produce_us={d}", .{ stats.layout_micros, stats.produce_micros });
    }
    try writer.writeByte('\n');
}

/// Test-only: collects the dump into an owned slice via the testing allocator (caller frees).
fn dumpToString(tree: *Tree, pretty: bool) ![]const u8 {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer sink.deinit();
    try dump(tree, &sink.writer, pretty);
    return sink.toOwnedSlice();
}

/// Test-only: collects the layout trace into an owned slice (caller frees).
fn traceToString(tree: *Tree, pretty: bool) ![]const u8 {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer sink.deinit();
    try dumpLayoutTrace(tree, &sink.writer, pretty);
    return sink.toOwnedSlice();
}

/// Test-only: collects the overlay dump into an owned slice (caller frees).
fn overlaysToString(tree: *Tree, pretty: bool) ![]const u8 {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer sink.deinit();
    try dumpOverlays(tree, &sink.writer, pretty);
    return sink.toOwnedSlice();
}

/// Test-only: collects the frame-stats dump into an owned slice (caller frees).
fn frameStatsToString(stats: FrameStats, pretty: bool) ![]const u8 {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer sink.deinit();
    try dumpFrameStats(stats, &sink.writer, pretty);
    return sink.toOwnedSlice();
}

test "machine dump is byte-identical across two runs on the same tree" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const child = try tree.createNode(.text);
    try tree.appendChild(root, child);

    const first = try dumpToString(&tree, false);
    defer std.testing.allocator.free(first);
    const second = try dumpToString(&tree, false);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "machine dump renders children in array order, not ascending id" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const anchor = try tree.createNode(.view);
    try tree.appendChild(root, anchor);
    const inserted = try tree.createNode(.view);
    try tree.insertBefore(root, inserted, anchor);

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    const expected =
        "node id=0 kind=view parent=none children=[2,1] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=2 kind=view parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=1 kind=view parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n";
    try std.testing.expectEqualStrings(expected, dumped);
}

test "machine dump walks a three-level tree in pre-order DFS, not breadth-first or id order" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const a = try tree.createNode(.view);
    const b = try tree.createNode(.view);
    const a1 = try tree.createNode(.view);
    const a2 = try tree.createNode(.view);
    try tree.appendChild(root, a);
    try tree.appendChild(root, b);
    try tree.appendChild(a, a1);
    try tree.appendChild(a, a2);

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    const expected =
        "node id=0 kind=view parent=none children=[1,2] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=1 kind=view parent=0 children=[3,4] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=3 kind=view parent=1 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=4 kind=view parent=1 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=2 kind=view parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n";
    try std.testing.expectEqualStrings(expected, dumped);
}

test "machine dump renders refs by id and none for a root" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const child = try tree.createNode(.text);
    try tree.appendChild(root, child);

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    const expected =
        "node id=0 kind=view parent=none children=[1] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=1 kind=text parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n";
    try std.testing.expectEqualStrings(expected, dumped);
}

test "machine dump reflects every prop field in the fixed line format" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const node = try tree.createNode(.text);
    Tree.updateNodeProps(node, .{
        .position_x = 12.5,
        .position_y = -3,
        .width = 360,
        .height = 48,
        .color_r = 0.92,
        .color_g = 0.1,
        .color_b = 0.25,
        .color_a = 1,
        .corner_radius = 8,
    });

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    const expected = "node id=0 kind=text parent=none children=[] pos=12.5000,-3.0000 size=360.0000,48.0000 color=0.9200,0.1000,0.2500,1.0000 radius=8.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=true\n";
    try std.testing.expectEqualStrings(expected, dumped);
}

test "machine dump contains no pointer addresses" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const child = try tree.createNode(.view);
    try tree.appendChild(root, child);

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    try std.testing.expect(std.mem.indexOf(u8, dumped, "0x") == null);
}

test "a removed subtree does not appear in the machine dump" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const keep = try tree.createNode(.view);
    const drop = try tree.createNode(.view);
    const drop_leaf = try tree.createNode(.text);
    try tree.appendChild(root, keep);
    try tree.appendChild(root, drop);
    try tree.appendChild(drop, drop_leaf);

    tree.removeNode(drop);

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    try std.testing.expect(std.mem.indexOf(u8, dumped, "id=2") == null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "id=3") == null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "id=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "id=1") != null);
}

test "pretty dump contains every node id" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const child = try tree.createNode(.text);
    try tree.appendChild(root, child);

    const dumped = try dumpToString(&tree, true);
    defer std.testing.allocator.free(dumped);

    try std.testing.expect(std.mem.indexOf(u8, dumped, "#0") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "#1") != null);
}

test "machine dump enumerates two roots by ascending id" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const first_root = try tree.createNode(.view);
    const second_root = try tree.createNode(.text);
    _ = first_root;
    _ = second_root;

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    const expected =
        "node id=0 kind=view parent=none children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=1 kind=text parent=none children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n";
    try std.testing.expectEqualStrings(expected, dumped);
}

test "machine dump appends the dirty flags and pretty surfaces them" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const clean = try tree.createNode(.view);
    const dirty = try tree.createNode(.view);
    dirty.layout_dirty = true;
    dirty.paint_dirty = true;
    try tree.appendChild(clean, dirty);

    const machine = try dumpToString(&tree, false);
    defer std.testing.allocator.free(machine);
    const pretty = try dumpToString(&tree, true);
    defer std.testing.allocator.free(pretty);

    const expected_machine =
        "node id=0 kind=view parent=none children=[1] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=false paint_dirty=false\n" ++
        "node id=1 kind=view parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=true paint_dirty=true\n";
    try std.testing.expectEqualStrings(expected_machine, machine);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "dirty=(layout=false, paint=false)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "dirty=(layout=true, paint=true)") != null);
}

test "machine dump reflects computed layout coordinates" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const node = try tree.createNode(.view);
    node.layout = .{ .x = 10, .y = 5, .w = 280, .h = 90 };

    const dumped = try dumpToString(&tree, false);
    defer std.testing.allocator.free(dumped);

    const expected = "node id=0 kind=view parent=none children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=10.0000,5.0000,280.0000,90.0000 layout_dirty=false paint_dirty=false\n";
    try std.testing.expectEqualStrings(expected, dumped);
}

test "layout trace machine dump is byte-identical across two runs" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 300, .h = 100 };
    const child = try tree.createNode(.view);
    child.layout = .{ .x = 0, .y = 0, .w = 150, .h = 100 };
    try tree.appendChild(root, child);

    const first = try traceToString(&tree, false);
    defer std.testing.allocator.free(first);
    const second = try traceToString(&tree, false);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "layout trace machine dump records avail and rect per node" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    root.direction = .row;
    root.padding_left = 10;
    root.padding_right = 10;
    root.padding_top = 5;
    root.padding_bottom = 5;
    root.layout = .{ .x = 0, .y = 0, .w = 300, .h = 100 };
    const child = try tree.createNode(.view);
    child.layout = .{ .x = 10, .y = 5, .w = 280, .h = 90 };
    try tree.appendChild(root, child);

    const trace = try traceToString(&tree, false);
    defer std.testing.allocator.free(trace);

    const expected =
        "node id=0 proposed=300.0000 preferred=0.0000,0.0000 avail=300.0000,100.0000 rect=0.0000,0.0000,300.0000,100.0000 measure=unmeasured glyphs=0 shape=unshaped\n" ++
        "node id=1 proposed=280.0000 preferred=0.0000,0.0000 avail=280.0000,90.0000 rect=10.0000,5.0000,280.0000,90.0000 measure=unmeasured glyphs=0 shape=unshaped\n";
    try std.testing.expectEqualStrings(expected, trace);
}

test "layout trace machine and pretty render the same coordinate values from one source" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    root.direction = .column;
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 300 };
    const child = try tree.createNode(.view);
    child.layout = .{ .x = 0, .y = 0, .w = 100, .h = 150 };
    try tree.appendChild(root, child);

    const machine = try traceToString(&tree, false);
    defer std.testing.allocator.free(machine);
    const pretty = try traceToString(&tree, true);
    defer std.testing.allocator.free(pretty);

    try std.testing.expect(std.mem.indexOf(u8, machine, "avail=300.0000,100.0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "avail=(300.0000, 100.0000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, machine, "rect=0.0000,0.0000,100.0000,150.0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "rect=(0.0000, 0.0000, 100.0000, 150.0000)") != null);
}

test "layout trace pretty renders indented avail/rect with the column projection for root and child" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    root.direction = .column;
    root.padding_left = 10;
    root.padding_right = 6;
    root.padding_top = 12;
    root.padding_bottom = 8;
    root.layout = .{ .x = 0, .y = 0, .w = 200, .h = 400 };
    const child = try tree.createNode(.view);
    child.layout = .{ .x = 10, .y = 12, .w = 184, .h = 180 };
    try tree.appendChild(root, child);

    const pretty = try traceToString(&tree, true);
    defer std.testing.allocator.free(pretty);

    const expected =
        "#0 proposed=400.0000 preferred=(0.0000, 0.0000) avail=(400.0000, 200.0000) rect=(0.0000, 0.0000, 200.0000, 400.0000) measure=unmeasured glyphs=0 shape=unshaped\n" ++
        "  #1 proposed=380.0000 preferred=(0.0000, 0.0000) avail=(380.0000, 184.0000) rect=(10.0000, 12.0000, 184.0000, 180.0000) measure=unmeasured glyphs=0 shape=unshaped\n";
    try std.testing.expectEqualStrings(expected, pretty);
}

test "layout trace enumerates two roots by ascending id" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const first_root = try tree.createNode(.view);
    first_root.layout = .{ .x = 0, .y = 0, .w = 200, .h = 50 };
    const second_root = try tree.createNode(.view);
    second_root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 80 };

    const trace = try traceToString(&tree, false);
    defer std.testing.allocator.free(trace);

    const expected =
        "node id=0 proposed=200.0000 preferred=0.0000,0.0000 avail=200.0000,50.0000 rect=0.0000,0.0000,200.0000,50.0000 measure=unmeasured glyphs=0 shape=unshaped\n" ++
        "node id=1 proposed=100.0000 preferred=0.0000,0.0000 avail=100.0000,80.0000 rect=0.0000,0.0000,100.0000,80.0000 measure=unmeasured glyphs=0 shape=unshaped\n";
    try std.testing.expectEqualStrings(expected, trace);
}

test "layout trace shows the measured proposed extent and a non-zero preferred on a fit_content tree" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    // A laid-out fit_content container around a child: the measure pass would
    // report a non-zero preferred (here filled directly — debug imports neither
    // measure nor layout) and the place pass the rect. The trace must surface a
    // non-zero proposed= (the offered wrap width) and preferred= for both nodes.
    const container = try tree.createNode(.view);
    container.sizing_mode = .fit_content;
    container.preferred = .{ .main = 120, .cross = 40 };
    container.layout = .{ .x = 0, .y = 0, .w = 120, .h = 40 };
    const child = try tree.createNode(.view);
    child.preferred = .{ .main = 120, .cross = 40 };
    child.layout = .{ .x = 0, .y = 0, .w = 120, .h = 40 };
    try tree.appendChild(container, child);

    const trace = try traceToString(&tree, false);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "node id=0 proposed=120.0000 preferred=120.0000,40.0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "node id=1 proposed=120.0000 preferred=120.0000,40.0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "preferred=0.0000,0.0000") == null);
}

test "layout trace marks a shaped text leaf with its glyph count and shape_cross provenance" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    // A .text leaf whose shape pass would have placed glyphs onto it (filled
    // directly here — debug imports neither the shape seam nor the arena). The
    // trace must surface the glyph count and the shape_cross provenance, while an
    // unshaped sibling stays glyphs=0 shape=unshaped.
    const placed = [_]tree_module.PlacedGlyph{
        .{ .center_x = 0, .center_y = 0, .width = 1, .height = 1, .atlas_min_u = 0, .atlas_min_v = 0, .atlas_max_u = 1, .atlas_max_v = 1 },
        .{ .center_x = 2, .center_y = 0, .width = 1, .height = 1, .atlas_min_u = 0, .atlas_min_v = 0, .atlas_max_u = 1, .atlas_max_v = 1 },
    };
    const shaped = try tree.createNode(.text);
    shaped.placed_glyphs = &placed;
    shaped.shape_source = .shape_cross;
    const unshaped = try tree.createNode(.text);
    try tree.appendChild(shaped, unshaped);

    const trace = try traceToString(&tree, false);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "node id=0 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "measure=unmeasured glyphs=2 shape=shape_cross\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "measure=unmeasured glyphs=0 shape=unshaped\n") != null);
}

test "overlay machine dump emits element bounds, dirty flags, and the hit rect per node, byte-deterministically" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const child = try tree.createNode(.view);
    child.layout = .{ .x = 10, .y = 20, .w = 80, .h = 40 };
    child.paint_dirty = true;
    try tree.appendChild(root, child);

    const first = try overlaysToString(&tree, false);
    defer std.testing.allocator.free(first);
    const second = try overlaysToString(&tree, false);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    const expected =
        "node id=0 element=0.0000,0.0000,200.0000,100.0000 dirty=layout=false,paint=false hit=0.0000,0.0000,200.0000,100.0000\n" ++
        "node id=1 element=10.0000,20.0000,80.0000,40.0000 dirty=layout=false,paint=true hit=10.0000,20.0000,80.0000,40.0000\n";
    try std.testing.expectEqualStrings(expected, first);
}

test "overlay pretty dump indents and surfaces the same element/hit values" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const child = try tree.createNode(.view);
    child.layout = .{ .x = 10, .y = 20, .w = 80, .h = 40 };
    try tree.appendChild(root, child);

    const pretty = try overlaysToString(&tree, true);
    defer std.testing.allocator.free(pretty);

    try std.testing.expect(std.mem.indexOf(u8, pretty, "#0 element=(0.0000, 0.0000, 200.0000, 100.0000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "  #1 element=(10.0000, 20.0000, 80.0000, 40.0000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "hit=(10.0000, 20.0000, 80.0000, 40.0000)") != null);
}

test "frame-stats machine dump omits the per-run timings and stays byte-identical across runs" {
    const stats = FrameStats{
        .instance_count = 3,
        .draw_call_count = 1,
        .recomputed_node_count = 0,
        .layout_micros = 42,
        .produce_micros = 17,
    };

    const machine = try frameStatsToString(stats, false);
    defer std.testing.allocator.free(machine);

    // The deterministic counters are present; the non-deterministic timings are not.
    try std.testing.expectEqualStrings("frame instances=3 draws=1 recomputed=0\n", machine);
    try std.testing.expect(std.mem.indexOf(u8, machine, "layout_us") == null);
    try std.testing.expect(std.mem.indexOf(u8, machine, "produce_us") == null);
}

test "frame-stats pretty dump adds the timings to the same counters" {
    const stats = FrameStats{
        .instance_count = 3,
        .draw_call_count = 1,
        .recomputed_node_count = 2,
        .layout_micros = 42,
        .produce_micros = 17,
    };

    const pretty = try frameStatsToString(stats, true);
    defer std.testing.allocator.free(pretty);

    try std.testing.expectEqualStrings("frame instances=3 draws=1 recomputed=2 layout_us=42 produce_us=17\n", pretty);
}
