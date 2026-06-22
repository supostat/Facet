const std = @import("std");
const tree = @import("tree.zig");
const measure = @import("measure.zig");
const Node = tree.Node;
const Tree = tree.Tree;
const Direction = tree.Direction;
const Align = tree.Align;
const SizingMode = tree.SizingMode;
const LayoutResult = tree.LayoutResult;

/// The absolute rectangle a container is laid out into. The root box is supplied
/// from above; inner boxes come from the place pass recursing into each child's
/// materialized rect (Ф9 made layout recursive over the two-phase pipeline).
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

/// The two-phase layout entry (Р11): run the bottom-up measure pass first so
/// each node's `preferred` is populated (fit_content/text drive sizing from
/// below), then the top-down place pass distributes and positions. The measure
/// pass is offered the container's own main extent as the proposed wrap width.
pub fn layout(t: *Tree, container: *Node, box: ContainerBox) std.mem.Allocator.Error!void {
    try measure.measure(t, container, AxisProjection.project(box, container.direction).main_extent);
    place(container, box);
}

/// Places container's children along its main axis at the given absolute box,
/// then recurses into each child's materialized rect (Р11 place pass). Per level:
/// sum the inflexible track (fixed/fit_content preferred main + gaps), give the
/// remaining free space to flex children by weight, position accumulating the
/// main-axis cursor with cross-axis alignment. No shrink — overflow (inflexible >
/// content) is a deterministic documented base case with no clamp (Р6/Р11).
fn place(container: *Node, box: ContainerBox) void {
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
        place(child, .{ .x = child.layout.x, .y = child.layout.y, .width = child.layout.w, .height = child.layout.h });
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
    for (container.children.items) |child| total += preferredMain(child);
    const gap_count: f32 = @floatFromInt(container.children.items.len - 1);
    return total + gap_count * container.gap;
}

fn totalFlex(container: *Node) f32 {
    var total: f32 = 0;
    for (container.children.items) |child| total += child.flex_grow;
    return total;
}

/// The main extent a child contributes to the inflexible track: a fixed child
/// its given size, a fit_content child its measured preferred main, a flex child
/// nothing (it consumes the remaining free space, distributed by weight).
fn preferredMain(child: *Node) f32 {
    return switch (child.sizing_mode) {
        .fixed => child.main_size orelse 0,
        .fit_content => child.preferred.main,
        .flex => 0,
    };
}

fn resolveChildMain(child: *Node, free_space: f32, total_flex: f32) f32 {
    return switch (child.sizing_mode) {
        .fixed => child.main_size orelse 0,
        .fit_content => child.preferred.main,
        .flex => if (free_space > 0 and total_flex != 0) free_space * (child.flex_grow / total_flex) else 0,
    };
}

fn resolveChildCross(child: *Node, cross_align: Align, cross_extent: f32) f32 {
    if (cross_align == .stretch) return cross_extent;
    return switch (child.sizing_mode) {
        .fixed, .flex => child.cross_size orelse 0,
        .fit_content => child.preferred.cross,
    };
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
    child.sizing_mode = .flex;
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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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
    try layout(&row_tree, row_container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    var column_tree = tree.Tree.init(testing.allocator);
    defer column_tree.deinit();
    const column_container = try column_tree.createNode(.view);
    column_container.direction = .column;
    column_container.cross_align = .stretch;
    const column_a = try fixedChild(&column_tree, 50, null);
    const column_b = try flexChild(&column_tree, 1, null);
    try column_tree.appendChild(column_container, column_a);
    try column_tree.appendChild(column_container, column_b);
    try layout(&column_tree, column_container, .{ .x = 0, .y = 0, .width = 100, .height = 300 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 0, .height = 100 });

    try testing.expectEqual(@as(f32, 0), a.layout.x);
    try testing.expectEqual(@as(f32, 0), a.layout.w);
    try testing.expectEqual(@as(f32, 0), b.layout.x);
    try testing.expectEqual(@as(f32, 0), b.layout.w);
}

test "a container with zero children is a no-op leaving the container box set" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);

    try layout(&t, container, .{ .x = 7, .y = 9, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 0, .height = 0 });

    try testing.expectEqual(@as(f32, 0), a.layout.w);
    try testing.expectEqual(@as(f32, 0), a.layout.h);
    try testing.expectEqual(@as(f32, 0), b.layout.w);
    try testing.expectEqual(@as(f32, 0), b.layout.h);
}

fn fitContentChild(t: *tree.Tree) !*Node {
    const child = try t.createNode(.view);
    child.sizing_mode = .fit_content;
    return child;
}

const ConstantMeasure = struct {
    main: f32,
    cross: f32,

    fn callback(self: *ConstantMeasure) tree.MeasureCallback {
        return .{ .context = self, .measure = report };
    }

    fn report(context: *anyopaque, _: []const u8, _: f32) tree.MeasuredSize {
        const self: *ConstantMeasure = @ptrCast(@alignCast(context));
        return .{ .main = self.main, .cross = self.cross };
    }
};

fn textChild(t: *tree.Tree, mock: *ConstantMeasure, string: []const u8) !*Node {
    const child = try t.createNode(.text);
    child.sizing_mode = .fit_content;
    child.text = string;
    child.measure_callback = mock.callback();
    return child;
}

test "a fit_content child takes its measured preferred main and the rest goes to flex" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const fit = try fitContentChild(&t);
    const inner = try fixedChild(&t, 120, null);
    try t.appendChild(fit, inner);
    const grow = try flexChild(&t, 1, null);
    try t.appendChild(container, fit);
    try t.appendChild(container, grow);

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 0), fit.layout.x);
    try testing.expectEqual(@as(f32, 120), fit.layout.w);
    try testing.expectEqual(@as(f32, 120), grow.layout.x);
    try testing.expectEqual(@as(f32, 180), grow.layout.w);
    try testing.expectEqual(@as(f32, 120), inner.layout.w);
}

test "a text leaf's measured size drives its fit_content parent's placed width" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();
    var mock = ConstantMeasure{ .main = 64, .cross = 18 };

    const container = try t.createNode(.view);
    const label = try fitContentChild(&t);
    const glyphs = try textChild(&t, &mock, "Save");
    try t.appendChild(label, glyphs);
    const rest = try flexChild(&t, 1, null);
    try t.appendChild(container, label);
    try t.appendChild(container, rest);

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    try testing.expectEqual(@as(f32, 64), label.layout.w);
    try testing.expectEqual(@as(f32, 0), glyphs.layout.x);
    try testing.expectEqual(@as(f32, 64), glyphs.layout.w);
    try testing.expectEqual(@as(f32, 64), rest.layout.x);
    try testing.expectEqual(@as(f32, 236), rest.layout.w);
}

test "nested fit_content places the outer width as the composed inner preference" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    const outer = try fitContentChild(&t);
    outer.gap = 8;
    const a = try fixedChild(&t, 25, null);
    const inner = try fitContentChild(&t);
    inner.gap = 5;
    const inner_a = try fixedChild(&t, 15, null);
    const inner_b = try fixedChild(&t, 35, null);
    try t.appendChild(inner, inner_a);
    try t.appendChild(inner, inner_b);
    try t.appendChild(outer, a);
    try t.appendChild(outer, inner);
    const tail = try flexChild(&t, 1, null);
    try t.appendChild(root, outer);
    try t.appendChild(root, tail);

    try layout(&t, root, .{ .x = 0, .y = 0, .width = 400, .height = 100 });

    const inner_main = 15 + 35 + 5;
    const outer_main = 25 + inner_main + 8;
    try testing.expectEqual(@as(f32, inner_main), inner.layout.w);
    try testing.expectEqual(@as(f32, outer_main), outer.layout.w);
    try testing.expectEqual(@as(f32, 25), a.layout.w);
    try testing.expectEqual(@as(f32, 25 + 8), inner.layout.x);
    try testing.expectEqual(@as(f32, outer_main), tail.layout.x);
    try testing.expectEqual(@as(f32, 400 - outer_main), tail.layout.w);
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

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 200, .height = 100 });

    const trace = try renderFailureTrace(&t);
    defer testing.allocator.free(trace);

    try testing.expect(std.mem.indexOf(u8, trace, "node id=0 proposed=200.0000 preferred=0.0000,0.0000 avail=200.0000,100.0000 rect=0.0000,0.0000,200.0000,100.0000") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "node id=1 proposed=200.0000 preferred=0.0000,0.0000 avail=200.0000,100.0000 rect=0.0000,0.0000,100.0000,0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "node id=2 proposed=200.0000 preferred=0.0000,0.0000 avail=200.0000,100.0000 rect=100.0000,0.0000,100.0000,0.0000") != null);
}

test "a failing layout assertion attaches the layout trace on the failure path" {
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();

    const container = try t.createNode(.view);
    const a = try flexChild(&t, 1, null);
    const b = try flexChild(&t, 1, null);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    try layout(&t, container, .{ .x = 0, .y = 0, .width = 200, .height = 100 });

    errdefer printLayoutTraceOnFailure(&t);
    try testing.expectEqual(@as(f32, 100), a.layout.w);
    try testing.expectEqual(@as(f32, 100), b.layout.w);
}
