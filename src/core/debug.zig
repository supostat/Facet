const std = @import("std");
const tree_module = @import("tree.zig");
const Tree = tree_module.Tree;
const Node = tree_module.Node;

/// Every float in the machine dump renders with this format: locale-independent
/// and byte-deterministic across runs (e.g. `360.0000`, `0.9200`, `0.0000`).
const FLOAT_FORMAT = "{d:.4}";

/// Dumps the shadow tree to writer. The machine form (pretty == false) is a
/// single deterministic line per node in a fixed field order, refs by id, no
/// pointer addresses, children in array order, roots enumerated by ascending id
/// (NOT hash-map order). The pretty form reuses the SAME walk and is free of the
/// byte-determinism contract. A single collection layer drives both outputs.
pub fn dump(tree: *Tree, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    var id: u32 = 0;
    while (id < tree.next_id) : (id += 1) {
        const node = tree.lookup(id) orelse continue;
        if (node.parent == null) try walk(node, writer, pretty, 0);
    }
}

fn walk(node: *Node, writer: *std.Io.Writer, pretty: bool, depth: usize) std.Io.Writer.Error!void {
    if (pretty) {
        try writePretty(node, writer, depth);
    } else {
        try writeMachine(node, writer);
    }
    for (node.children.items) |child| try walk(child, writer, pretty, depth + 1);
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
    try writer.print(" radius=" ++ FLOAT_FORMAT ++ "\n", .{node.corner_radius});
}

fn writePretty(node: *Node, writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    var indent: usize = 0;
    while (indent < depth) : (indent += 1) try writer.writeAll("  ");
    try writer.print("{s}#{d}", .{ @tagName(node.kind), node.id });
    try writer.print(" pos=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")", .{ node.position_x, node.position_y });
    try writer.print(" size=(" ++ FLOAT_FORMAT ++ ", " ++ FLOAT_FORMAT ++ ")\n", .{ node.width, node.height });
}

/// Test-only: collects the dump into an owned slice via the testing allocator (caller frees).
fn dumpToString(tree: *Tree, pretty: bool) ![]const u8 {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer sink.deinit();
    try dump(tree, &sink.writer, pretty);
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
        "node id=0 kind=view parent=none children=[2,1] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n" ++
        "node id=2 kind=view parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n" ++
        "node id=1 kind=view parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n";
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
        "node id=0 kind=view parent=none children=[1,2] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n" ++
        "node id=1 kind=view parent=0 children=[3,4] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n" ++
        "node id=3 kind=view parent=1 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n" ++
        "node id=4 kind=view parent=1 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n" ++
        "node id=2 kind=view parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n";
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
        "node id=0 kind=view parent=none children=[1] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n" ++
        "node id=1 kind=text parent=0 children=[] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000\n";
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

    const expected = "node id=0 kind=text parent=none children=[] pos=12.5000,-3.0000 size=360.0000,48.0000 color=0.9200,0.1000,0.2500,1.0000 radius=8.0000\n";
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
