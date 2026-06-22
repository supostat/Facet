const std = @import("std");
const tree = @import("tree.zig");
const layout = @import("layout.zig");
const Tree = tree.Tree;
const Node = tree.Node;

/// The mutable props a host can change on a node, named 1:1 with the real Node
/// fields. Each maps to exactly one DirtyClass via `classify`: a paint prop
/// changes only the rendered pixels, a layout prop changes the geometry and must
/// trigger a re-measure/re-place of the affected subtree (Р12 dirty tracking).
pub const Prop = enum {
    position_x,
    position_y,
    width,
    height,
    color_r,
    color_g,
    color_b,
    color_a,
    corner_radius,
    main_size,
    cross_size,
    padding_top,
    padding_right,
    padding_bottom,
    padding_left,
    gap,
    flex_grow,
    cross_align,
    direction,
    text,
};

/// The two consequences a prop change can have. A paint change repaints in place
/// without touching geometry; a layout change invalidates the measure/place
/// result and bubbles up to the nearest fixed-main ancestor. There is no `.both`:
/// every prop falls into exactly one class (width/height are RENDER-only — the
/// layout source of truth is main_size/cross_size — so they are paint).
pub const DirtyClass = enum { layout, paint };

/// The single authority mapping a prop to its dirty class. A TOTAL switch with no
/// default so adding a Prop variant is a compile error until classified here.
/// Layout drivers: the explicit sizes (main_size/cross_size), the box model
/// (padding_*/gap), and the flow controls (flex_grow/cross_align/direction/text,
/// whose measured content drives a fit_content parent). Paint-only: position_*,
/// the render-only width/height, color_*, and corner_radius.
fn classify(prop: Prop) DirtyClass {
    return switch (prop) {
        .main_size,
        .cross_size,
        .padding_top,
        .padding_right,
        .padding_bottom,
        .padding_left,
        .gap,
        .flex_grow,
        .cross_align,
        .direction,
        .text,
        => .layout,
        .position_x,
        .position_y,
        .width,
        .height,
        .color_r,
        .color_g,
        .color_b,
        .color_a,
        .corner_radius,
        => .paint,
    };
}

/// Marks a node dirty for a single changed prop. A paint change raises only this
/// node's paint flag; a layout change bubbles layout_dirty up the ancestor chain
/// to (and including) the nearest fixed-main container, since a fixed-main
/// ancestor's own geometry cannot change from a descendant's content.
pub fn markDirty(node: *Node, prop: Prop) void {
    switch (classify(prop)) {
        .paint => node.paint_dirty = true,
        .layout => bubbleLayoutDirty(node),
    }
}

/// Walks parent links setting layout_dirty on each, stopping INCLUSIVE at the
/// first node whose main-axis size is fixed (it is marked, then we return): a
/// fixed-main container clips the re-measure, since its preferred size does not
/// depend on its children. Terminates at the root (parent == null) otherwise.
fn bubbleLayoutDirty(node: *Node) void {
    var walk: ?*Node = node;
    while (walk) |current| {
        current.layout_dirty = true;
        if (tree.hasFixedMainSize(current)) return;
        walk = current.parent;
    }
}

/// Recomputes the layout of every maximal dirty subtree under root and clears the
/// layout_dirty flags it processes, returning the count of nodes that carried
/// layout_dirty at pass entry. A maximal dirty subtree root is a dirty node with
/// no dirty-recomputed ancestor; recomputing it via layout.recomputeSubtree
/// re-measures and re-places that whole subtree, so nested dirty descendants need
/// no separate recompute — they are only counted and cleared.
pub fn recomputeDirty(t: *Tree, root: *Node) std.mem.Allocator.Error!usize {
    var recomputed: usize = 0;
    try recomputeWalk(t, root, false, &recomputed);
    return recomputed;
}

fn recomputeWalk(t: *Tree, node: *Node, ancestor_recomputed: bool, recomputed: *usize) std.mem.Allocator.Error!void {
    const is_subtree_root = node.layout_dirty and !ancestor_recomputed;
    if (is_subtree_root) try layout.recomputeSubtree(t, node);
    const covered = ancestor_recomputed or is_subtree_root;
    if (node.layout_dirty) {
        node.layout_dirty = false;
        recomputed.* += 1;
    }
    for (node.children.items) |child| try recomputeWalk(t, child, covered, recomputed);
}

const testing = std.testing;

/// A measure source that counts callback crossings and models wrap (a narrower
/// proposed width yields a taller cross), so a test can prove the measure cache
/// shields it across a recompute. Mirrors measure.zig's MockMeasure.
const MockMeasure = struct {
    crossings: usize = 0,
    fixed_main: f32,

    fn callback(self: *MockMeasure) tree.MeasureCallback {
        return .{ .context = self, .measure = measureGlyphs };
    }

    fn measureGlyphs(context: *anyopaque, text: []const u8, proposed_main: f32) tree.MeasuredSize {
        const self: *MockMeasure = @ptrCast(@alignCast(context));
        self.crossings += 1;
        const lines = if (proposed_main <= 0) 1 else @ceil(self.fixed_main / proposed_main);
        return .{
            .main = @min(self.fixed_main, @max(proposed_main, 0)),
            .cross = @as(f32, @floatFromInt(text.len)) * lines,
        };
    }
};

fn fitContent(t: *Tree, direction: tree.Direction) !*Node {
    const node = try t.createNode(.view);
    node.sizing_mode = .fit_content;
    node.direction = direction;
    return node;
}

fn fixedNode(t: *Tree, main_size: f32, cross_size: f32) !*Node {
    const node = try t.createNode(.view);
    node.sizing_mode = .fixed;
    node.main_size = main_size;
    node.cross_size = cross_size;
    return node;
}

test "a paint prop raises only paint_dirty and recompute crosses nothing" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const root = try fitContent(&t, .row);
    const child = try fixedNode(&t, 50, 20);
    try t.appendChild(root, child);
    try layout.layout(&t, root, .{ .x = 0, .y = 0, .width = 50, .height = 20 });
    const crossings_after_layout = t.measure_cache.invocation_count;

    markDirty(child, .color_r);

    try testing.expect(child.paint_dirty);
    try testing.expect(!child.layout_dirty);
    try testing.expect(!root.layout_dirty);

    const recomputed = try recomputeDirty(&t, root);
    try testing.expectEqual(@as(usize, 0), recomputed);
    try testing.expectEqual(crossings_after_layout, t.measure_cache.invocation_count);
}

test "a text change bubbles to the fit_content root and the recompute crosses once" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 60 };

    const root = try fitContent(&t, .row);
    const label = try t.createNode(.text);
    label.sizing_mode = .fit_content;
    label.text = "abcd";
    label.measure_callback = mock.callback();
    try t.appendChild(root, label);
    try layout.layout(&t, root, .{ .x = 0, .y = 0, .width = 200, .height = 100 });
    const crossings_after_layout = mock.crossings;
    const invocations_after_layout = t.measure_cache.invocation_count;

    label.text = "abcdef";
    markDirty(label, .text);

    try testing.expect(label.layout_dirty);
    try testing.expect(root.layout_dirty);

    const recomputed = try recomputeDirty(&t, root);
    try testing.expectEqual(@as(usize, 2), recomputed);
    try testing.expectEqual(crossings_after_layout + 1, mock.crossings);
    try testing.expectEqual(invocations_after_layout + 1, t.measure_cache.invocation_count);
    try testing.expect(!label.layout_dirty);
    try testing.expect(!root.layout_dirty);
}

test "bubbling stops inclusive at the nearest fixed-main ancestor and a descendant recompute leaves the fixed ancestor's geometry byte-identical" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 30 };

    const root = try fitContent(&t, .row);
    const mid = try fixedNode(&t, 80, 40);
    const inner = try fitContent(&t, .row);
    const leaf = try t.createNode(.text);
    leaf.sizing_mode = .fit_content;
    leaf.text = "abc";
    leaf.measure_callback = mock.callback();
    try t.appendChild(root, mid);
    try t.appendChild(mid, inner);
    try t.appendChild(inner, leaf);
    try layout.layout(&t, root, .{ .x = 0, .y = 0, .width = 200, .height = 100 });
    const root_layout_before = root.layout;

    markDirty(inner, .gap);

    try testing.expect(leaf.layout_dirty == false);
    try testing.expect(inner.layout_dirty);
    try testing.expect(mid.layout_dirty);
    try testing.expect(!root.layout_dirty);

    leaf.layout_dirty = true;
    const recomputed = try recomputeDirty(&t, root);

    try testing.expectEqual(@as(usize, 3), recomputed);
    try testing.expectEqual(root_layout_before.x, root.layout.x);
    try testing.expectEqual(root_layout_before.y, root.layout.y);
    try testing.expectEqual(root_layout_before.w, root.layout.w);
    try testing.expectEqual(root_layout_before.h, root.layout.h);
    try testing.expect(!root.layout_dirty);
    try testing.expect(!mid.layout_dirty);
    try testing.expect(!inner.layout_dirty);
    try testing.expect(!leaf.layout_dirty);
}

test "a layout change on a node that is itself fixed-main marks only that node" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const root = try fitContent(&t, .row);
    const fixed = try fixedNode(&t, 80, 40);
    try t.appendChild(root, fixed);

    markDirty(fixed, .gap);

    try testing.expect(fixed.layout_dirty);
    try testing.expect(!root.layout_dirty);
}

test "nested dirty under a recomputed root recomputes once and counts both" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const root = try fixedNode(&t, 300, 100);
    const middle = try fitContent(&t, .row);
    const leaf = try fixedNode(&t, 40, 20);
    try t.appendChild(root, middle);
    try t.appendChild(middle, leaf);
    try layout.layout(&t, root, .{ .x = 0, .y = 0, .width = 300, .height = 100 });

    middle.layout_dirty = true;
    leaf.layout_dirty = true;

    const recomputed = try recomputeDirty(&t, root);

    try testing.expectEqual(@as(usize, 2), recomputed);
    try testing.expect(!middle.layout_dirty);
    try testing.expect(!leaf.layout_dirty);
}

test "a clean recompute over an unchanged text subtree hits the cache and never re-measures" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 60 };

    const root = try fixedNode(&t, 200, 100);
    const inner = try fitContent(&t, .row);
    const label = try t.createNode(.text);
    label.sizing_mode = .fit_content;
    label.text = "abcd";
    label.measure_callback = mock.callback();
    try t.appendChild(root, inner);
    try t.appendChild(inner, label);
    try layout.layout(&t, root, .{ .x = 0, .y = 0, .width = 200, .height = 100 });
    const crossings_after_layout = mock.crossings;
    const invocations_after_layout = t.measure_cache.invocation_count;

    // The subtree is unchanged: recompute from the SAME root, so the leaf is
    // re-measured at the SAME proposed main extent (the root's) as the first pass
    // — an identical (string, proposed_main) key that the cache must shield.
    root.layout_dirty = true;
    const recomputed = try recomputeDirty(&t, root);

    try testing.expectEqual(@as(usize, 1), recomputed);
    try testing.expectEqual(crossings_after_layout, mock.crossings);
    try testing.expectEqual(invocations_after_layout, t.measure_cache.invocation_count);
}

test "recomputing one subtree leaves a clean sibling's coordinates byte-identical and crosses nothing" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 50 };

    // The top-level layout proposes the root's main extent to EVERY descendant, so
    // dirty_branch is given a main_size equal to that extent: a later
    // recomputeSubtree(dirty_branch) re-measures dirty_label at the SAME proposed
    // main, an identical cache key the cache must shield (delta +0).
    const root = try fixedNode(&t, 80, 100);
    const dirty_branch = try fixedNode(&t, 80, 40);
    const clean_sibling = try fixedNode(&t, 70, 30);
    const clean_grandchild = try fixedNode(&t, 20, 10);
    const dirty_label = try t.createNode(.text);
    dirty_label.sizing_mode = .fit_content;
    dirty_label.text = "xyz";
    dirty_label.measure_callback = mock.callback();
    try t.appendChild(root, dirty_branch);
    try t.appendChild(root, clean_sibling);
    try t.appendChild(dirty_branch, dirty_label);
    try t.appendChild(clean_sibling, clean_grandchild);
    try layout.layout(&t, root, .{ .x = 0, .y = 0, .width = 80, .height = 100 });
    const sibling_layout_before = clean_sibling.layout;
    const grandchild_layout_before = clean_grandchild.layout;
    const crossings_after_layout = mock.crossings;
    const invocations_after_layout = t.measure_cache.invocation_count;

    markDirty(dirty_branch, .gap);
    const recomputed = try recomputeDirty(&t, root);

    try testing.expect(recomputed < t.nodes.count());
    try testing.expectEqual(@as(usize, 1), recomputed);
    try testing.expectEqual(sibling_layout_before.x, clean_sibling.layout.x);
    try testing.expectEqual(sibling_layout_before.y, clean_sibling.layout.y);
    try testing.expectEqual(sibling_layout_before.w, clean_sibling.layout.w);
    try testing.expectEqual(sibling_layout_before.h, clean_sibling.layout.h);
    try testing.expectEqual(grandchild_layout_before.x, clean_grandchild.layout.x);
    try testing.expectEqual(grandchild_layout_before.y, clean_grandchild.layout.y);
    try testing.expectEqual(grandchild_layout_before.w, clean_grandchild.layout.w);
    try testing.expectEqual(grandchild_layout_before.h, clean_grandchild.layout.h);
    try testing.expectEqual(crossings_after_layout, mock.crossings);
    try testing.expectEqual(invocations_after_layout, t.measure_cache.invocation_count);
}

/// The expected class of every Prop variant, pinned independently of `classify`'s
/// own switch so a miswiring (e.g. text -> .paint) fails the test. The comptime
/// length check against the enum's field count makes the table exhaustive: adding
/// a Prop variant without listing it here is a compile error, so no future prop
/// escapes the classification lock.
const expected_class = [_]struct { prop: Prop, class: DirtyClass }{
    .{ .prop = .position_x, .class = .paint },
    .{ .prop = .position_y, .class = .paint },
    .{ .prop = .width, .class = .paint },
    .{ .prop = .height, .class = .paint },
    .{ .prop = .color_r, .class = .paint },
    .{ .prop = .color_g, .class = .paint },
    .{ .prop = .color_b, .class = .paint },
    .{ .prop = .color_a, .class = .paint },
    .{ .prop = .corner_radius, .class = .paint },
    .{ .prop = .main_size, .class = .layout },
    .{ .prop = .cross_size, .class = .layout },
    .{ .prop = .padding_top, .class = .layout },
    .{ .prop = .padding_right, .class = .layout },
    .{ .prop = .padding_bottom, .class = .layout },
    .{ .prop = .padding_left, .class = .layout },
    .{ .prop = .gap, .class = .layout },
    .{ .prop = .flex_grow, .class = .layout },
    .{ .prop = .cross_align, .class = .layout },
    .{ .prop = .direction, .class = .layout },
    .{ .prop = .text, .class = .layout },
};

test "classify maps every prop to its dirty class" {
    comptime std.debug.assert(expected_class.len == @typeInfo(Prop).@"enum".fields.len);
    for (expected_class) |entry| {
        try testing.expectEqual(entry.class, classify(entry.prop));
    }
}

test "every render prop updateNodeProps writes is paint-class under classify" {
    inline for (Tree.render_props) |name| {
        @setEvalBranchQuota(10_000);
        const prop = comptime std.meta.stringToEnum(Prop, name) orelse
            @compileError("render_props name has no matching Prop: " ++ name);
        try testing.expectEqual(DirtyClass.paint, classify(prop));
    }
}
