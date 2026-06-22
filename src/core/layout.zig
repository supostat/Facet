const std = @import("std");
const tree = @import("tree.zig");
const Node = tree.Node;
const Direction = tree.Direction;
const Align = tree.Align;
const LayoutResult = tree.LayoutResult;

/// The absolute rectangle a container is laid out into, supplied from above (no
/// measure phase in this block — every container size comes from its parent).
pub const ContainerBox = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// A rectangle projected onto the active direction's main/cross axes. This is the
/// ONLY place that knows main == horizontal for row and main == vertical for
/// column; the rest of the engine reasons purely in main/cross terms (Р11).
pub const AxisProjection = struct {
    main_start: f32,
    cross_start: f32,
    main_extent: f32,
    cross_extent: f32,

    fn project(box: ContainerBox, direction: Direction) AxisProjection {
        return switch (direction) {
            .row => .{ .main_start = box.x, .cross_start = box.y, .main_extent = box.width, .cross_extent = box.height },
            .column => .{ .main_start = box.y, .cross_start = box.x, .main_extent = box.height, .cross_extent = box.width },
        };
    }

    fn materialize(direction: Direction, main_pos: f32, cross_pos: f32, main_len: f32, cross_len: f32) LayoutResult {
        return switch (direction) {
            .row => .{ .x = main_pos, .y = cross_pos, .w = main_len, .h = cross_len },
            .column => .{ .x = cross_pos, .y = main_pos, .w = cross_len, .h = main_len },
        };
    }
};

/// Lays out container's children along its main axis at the given absolute box.
/// Single pass: sum the inflexible track (fixed child main sizes + gaps), give
/// the remaining free space to flex children by weight, then place each child
/// accumulating the main-axis cursor and applying cross-axis alignment. No
/// measure phase, no shrink — overflow (inflexible > content) is a deterministic
/// documented base case with no clamp (Р6/Р11).
pub fn layout(container: *Node, box: ContainerBox) void {
    container.layout = .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height };
    if (container.children.items.len == 0) return;

    const direction = container.direction;
    const space = AxisProjection.project(contentBox(container, box), direction);
    const free_space = space.main_extent - inflexibleMain(container);
    const total_flex = totalFlex(container);

    var cursor = space.main_start;
    for (container.children.items, 0..) |child, index| {
        if (index != 0) cursor += container.gap;
        const child_main = resolveChildMain(child, free_space, total_flex);
        const child_cross = resolveChildCross(child, container.cross_align, space.cross_extent);
        const cross_pos = crossPosition(container.cross_align, space.cross_start, space.cross_extent, child_cross);
        child.layout = AxisProjection.materialize(direction, cursor, cross_pos, child_main, child_cross);
        cursor += child_main;
    }
}

fn contentBox(container: *Node, box: ContainerBox) ContainerBox {
    return .{
        .x = box.x + container.padding_left,
        .y = box.y + container.padding_top,
        .width = box.width - container.padding_left - container.padding_right,
        .height = box.height - container.padding_top - container.padding_bottom,
    };
}

fn inflexibleMain(container: *Node) f32 {
    var total: f32 = 0;
    for (container.children.items) |child| total += child.main_size orelse 0;
    const gap_count: f32 = @floatFromInt(container.children.items.len - 1);
    return total + gap_count * container.gap;
}

fn totalFlex(container: *Node) f32 {
    var total: f32 = 0;
    for (container.children.items) |child| total += child.flex_grow;
    return total;
}

fn resolveChildMain(child: *Node, free_space: f32, total_flex: f32) f32 {
    if (child.main_size) |fixed| return fixed;
    if (free_space > 0 and total_flex != 0) return free_space * (child.flex_grow / total_flex);
    return 0;
}

fn resolveChildCross(child: *Node, cross_align: Align, cross_extent: f32) f32 {
    if (cross_align == .stretch) return cross_extent;
    return child.cross_size orelse 0;
}

fn crossPosition(cross_align: Align, cross_start: f32, cross_extent: f32, child_cross: f32) f32 {
    return switch (cross_align) {
        .start, .stretch => cross_start,
        .center => cross_start + (cross_extent - child_cross) / 2,
        .end => cross_start + (cross_extent - child_cross),
    };
}

const testing = std.testing;

fn fixedChild(t: *tree.Tree, main_size: f32, cross_size: ?f32) !*Node {
    const child = try t.createNode(.view);
    child.main_size = main_size;
    child.cross_size = cross_size;
    return child;
}

fn flexChild(t: *tree.Tree, flex_grow: f32, cross_size: ?f32) !*Node {
    const child = try t.createNode(.view);
    child.flex_grow = flex_grow;
    child.cross_size = cross_size;
    return child;
}

test "three flex:1 children split the main size equally" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 1, null);
    const c = try flexChild(&t, 1, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);
    try t.appendChild(container, c);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), a.layout.x);
    try testing.expectEqual(@as(f32, 100), a.layout.w);
    try testing.expectEqual(@as(f32, 100), b.layout.x);
    try testing.expectEqual(@as(f32, 100), b.layout.w);
    try testing.expectEqual(@as(f32, 200), c.layout.x);
    try testing.expectEqual(@as(f32, 100), c.layout.w);
}

test "a fixed child plus flex children distributes the remainder by weight" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const fixed = try fixedChild(&t, 100, null);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 1, null);
    try t.appendChild(container, fixed);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), fixed.layout.x);
    try testing.expectEqual(@as(f32, 100), fixed.layout.w);
    try testing.expectEqual(@as(f32, 100), a.layout.x);
    try testing.expectEqual(@as(f32, 100), a.layout.w);
    try testing.expectEqual(@as(f32, 200), b.layout.x);
    try testing.expectEqual(@as(f32, 100), b.layout.w);
}

test "weighted flex divides free space 1:2" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 2, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), a.layout.x);
    try testing.expectEqual(@as(f32, 100), a.layout.w);
    try testing.expectEqual(@as(f32, 100), b.layout.x);
    try testing.expectEqual(@as(f32, 200), b.layout.w);
}

test "gap is in the inflexible subtraction and the placement cursor" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.gap = 20;
    const a = try fixedChild(&t, 50, null);
    const b = try fixedChild(&t, 50, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), a.layout.x);
    try testing.expectEqual(@as(f32, 50), a.layout.w);
    try testing.expectEqual(@as(f32, 70), b.layout.x);
    try testing.expectEqual(@as(f32, 50), b.layout.w);
}

test "padding shrinks the content box and offsets children by leading padding" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.padding_left = 10;
    container.padding_right = 10;
    container.padding_top = 5;
    container.padding_bottom = 5;
    container.cross_align = .stretch;
    const child = try flexChild(&t, 1, null);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 10), child.layout.x);
    try testing.expectEqual(@as(f32, 5), child.layout.y);
    try testing.expectEqual(@as(f32, 280), child.layout.w);
    try testing.expectEqual(@as(f32, 90), child.layout.h);
}

test "cross align start places a fixed cross size at the content cross start" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.cross_align = .start;
    const child = try flexChild(&t, 1, 40);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), child.layout.y);
    try testing.expectEqual(@as(f32, 40), child.layout.h);
}

test "cross align center centers a fixed cross size" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.cross_align = .center;
    const child = try flexChild(&t, 1, 40);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 30), child.layout.y);
    try testing.expectEqual(@as(f32, 40), child.layout.h);
}

test "cross align end places a fixed cross size at the far edge" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.cross_align = .end;
    const child = try flexChild(&t, 1, 40);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 60), child.layout.y);
    try testing.expectEqual(@as(f32, 40), child.layout.h);
}

test "cross align center overflow yields a deterministic negative offset" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.cross_align = .center;
    const child = try flexChild(&t, 1, 140);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, -20), child.layout.y);
    try testing.expectEqual(@as(f32, 140), child.layout.h);
}

test "cross align end overflow yields a deterministic negative offset" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.cross_align = .end;
    const child = try flexChild(&t, 1, 140);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, -40), child.layout.y);
    try testing.expectEqual(@as(f32, 140), child.layout.h);
}

test "stretch ignores a set cross size and fills the content cross extent" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.cross_align = .stretch;
    const child = try flexChild(&t, 1, 40);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), child.layout.y);
    try testing.expectEqual(@as(f32, 100), child.layout.h);
}

test "row and column produce mirrored coordinates from one code path" {
    var row_tree = tree.Tree.init(testing.allocator);
    defer row_tree.deinit();
    const row_container = try row_tree.createNode(.view);
    row_container.direction = .row;
    row_container.cross_align = .stretch;
    const row_a = try fixedChild(&row_tree, 50, null);
    const row_b = try flexChild(&row_tree, 1, null);
    try row_tree.appendChild(row_container, row_a);
    try row_tree.appendChild(row_container, row_b);
    layout(row_container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    var column_tree = tree.Tree.init(testing.allocator);
    defer column_tree.deinit();
    const column_container = try column_tree.createNode(.view);
    column_container.direction = .column;
    column_container.cross_align = .stretch;
    const column_a = try fixedChild(&column_tree, 50, null);
    const column_b = try flexChild(&column_tree, 1, null);
    try column_tree.appendChild(column_container, column_a);
    try column_tree.appendChild(column_container, column_b);
    layout(column_container, .{ .x = 0, .y = 0, .width = 100, .height = 300 });

    try testing.expectEqual(@as(f32, 250), row_b.layout.w);
    try testing.expectEqual(row_a.layout.x, column_a.layout.y);
    try testing.expectEqual(row_a.layout.y, column_a.layout.x);
    try testing.expectEqual(row_a.layout.w, column_a.layout.h);
    try testing.expectEqual(row_a.layout.h, column_a.layout.w);
    try testing.expectEqual(row_b.layout.x, column_b.layout.y);
    try testing.expectEqual(row_b.layout.y, column_b.layout.x);
    try testing.expectEqual(row_b.layout.w, column_b.layout.h);
    try testing.expectEqual(row_b.layout.h, column_b.layout.w);
}

test "underflow keeps fixed sizes and overflows with no shrink" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try fixedChild(&t, 200, null);
    const b = try fixedChild(&t, 200, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), a.layout.x);
    try testing.expectEqual(@as(f32, 200), a.layout.w);
    try testing.expectEqual(@as(f32, 200), b.layout.x);
    try testing.expectEqual(@as(f32, 200), b.layout.w);
}

test "all-flex children in non-positive free space get zero main length" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 1, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 0, .height = 100 });

    try testing.expectEqual(@as(f32, 0), a.layout.x);
    try testing.expectEqual(@as(f32, 0), a.layout.w);
    try testing.expectEqual(@as(f32, 0), b.layout.x);
    try testing.expectEqual(@as(f32, 0), b.layout.w);
}

test "a container with zero children is a no-op leaving the container box set" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);

    layout(container, .{ .x = 7, .y = 9, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 7), container.layout.x);
    try testing.expectEqual(@as(f32, 9), container.layout.y);
    try testing.expectEqual(@as(f32, 300), container.layout.w);
    try testing.expectEqual(@as(f32, 100), container.layout.h);
}

test "a single flex child fills the content box" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    container.cross_align = .stretch;
    const child = try flexChild(&t, 1, null);
    try t.appendChild(container, child);

    layout(container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), child.layout.x);
    try testing.expectEqual(@as(f32, 0), child.layout.y);
    try testing.expectEqual(@as(f32, 300), child.layout.w);
    try testing.expectEqual(@as(f32, 100), child.layout.h);
}

test "a zero-size container lays out flex children with no division by zero" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 1, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 0, .height = 0 });

    try testing.expectEqual(@as(f32, 0), a.layout.w);
    try testing.expectEqual(@as(f32, 0), a.layout.h);
    try testing.expectEqual(@as(f32, 0), b.layout.w);
    try testing.expectEqual(@as(f32, 0), b.layout.h);
}

const debug = @import("debug.zig");

fn renderFailureTrace(t: *tree.Tree) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer sink.deinit();
    try debug.dumpLayoutTrace(t, &sink.writer, false);
    return sink.toOwnedSlice();
}

fn printLayoutTraceOnFailure(t: *tree.Tree) void {
    const trace = renderFailureTrace(t) catch return;
    defer testing.allocator.free(trace);
    std.debug.print("\nlayout trace at failure:\n{s}", .{trace});
}

test "the failure-trace renderer emits the laid-out avail and rect of every node" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 1, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 200, .height = 100 });

    const trace = try renderFailureTrace(&t);
    defer testing.allocator.free(trace);

    try testing.expect(std.mem.indexOf(u8, trace, "node id=0 avail=200.0000,100.0000 rect=0.0000,0.0000,200.0000,100.0000") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "node id=1 avail=200.0000,100.0000 rect=0.0000,0.0000,100.0000,0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "node id=2 avail=200.0000,100.0000 rect=100.0000,0.0000,100.0000,0.0000") != null);
}

test "a failing layout assertion attaches the layout trace on the failure path" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 1, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    layout(container, .{ .x = 0, .y = 0, .width = 200, .height = 100 });

    errdefer printLayoutTraceOnFailure(&t);
    try testing.expectEqual(@as(f32, 100), a.layout.w);
    try testing.expectEqual(@as(f32, 100), b.layout.w);
}
