const std = @import("std");
const tree = @import("tree.zig");
const Tree = tree.Tree;
const Node = tree.Node;
const Direction = tree.Direction;
const SizingMode = tree.SizingMode;
const MeasuredSize = tree.MeasuredSize;
const MeasureSource = tree.MeasureSource;
const PreferredSize = tree.PreferredSize;

/// A `(string, proposed main extent) -> MeasuredSize` memoization for text-node
/// measurement (Р10). A repeated measure with an unchanged key MUST hit the
/// cache and NOT re-invoke the callback (the crossing the Phase 14 Core Text
/// seam relies on): invocation_count counts callback crossings, asserted == 1
/// for a stable string, == 2 for two distinct widths. The cache and the strings
/// it interns are arena-backed (the Tree's arena), so there is no explicit
/// deinit — arena.deinit() frees them wholesale.
pub const MeasureCache = struct {
    /// A cache key pairs the text with the proposed main-axis extent: a different
    /// wrap width is a distinct entry (a narrower width may wrap to a taller box).
    const Key = struct {
        text: []const u8,
        proposed_main: f32,
    };

    const KeyContext = struct {
        pub fn hash(_: KeyContext, key: Key) u32 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key.text);
            hasher.update(std.mem.asBytes(&key.proposed_main));
            return @truncate(hasher.final());
        }

        pub fn eql(_: KeyContext, a: Key, b: Key, _: usize) bool {
            return std.mem.eql(u8, a.text, b.text) and a.proposed_main == b.proposed_main;
        }
    };

    entries: std.ArrayHashMap(Key, MeasuredSize, KeyContext, true),
    invocation_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MeasureCache {
        return .{
            .entries = std.ArrayHashMap(Key, MeasuredSize, KeyContext, true).init(allocator),
        };
    }

    /// A measured size paired with its provenance: `.cache_hit` when the (text,
    /// width) key was served from the cache without crossing the seam, or
    /// `.seam_cross` when the callback was invoked on a miss (a real Zig→Swift
    /// transition). `measureNode` writes the source onto the node so debug surfaces
    /// it and the e2e proves the cache HIT bypasses the seam (Р10 anti-chatty-seam).
    const CachedMeasure = struct {
        size: MeasuredSize,
        source: MeasureSource,
    };

    /// Returns the measured size for (text, proposed_main) WITH its provenance,
    /// invoking callback and caching on a miss (`.seam_cross`), returning the
    /// cached value with NO callback crossing on a hit (`.cache_hit`). On a miss
    /// the text is duped into the arena (via the managed map's own allocator, which
    /// `measure()` rebinds from the stable *Tree) and the DUPED slice is stored as
    /// the key, never the caller's transient slice (whose backing may outlive
    /// nothing the cache controls).
    fn measureCached(
        self: *MeasureCache,
        callback: tree.MeasureCallback,
        text: []const u8,
        proposed_main: f32,
    ) std.mem.Allocator.Error!CachedMeasure {
        const probe = Key{ .text = text, .proposed_main = proposed_main };
        if (self.entries.get(probe)) |cached| return .{ .size = cached, .source = .cache_hit };

        const measured = callback.measure(callback.context, text, proposed_main);
        const interned = try self.entries.allocator.dupe(u8, text);
        try self.entries.put(.{ .text = interned, .proposed_main = proposed_main }, measured);
        self.invocation_count += 1;
        return .{ .size = measured, .source = .seam_cross };
    }
};

/// The bottom-up measure pass (Р11, first half of layout): a leaves-to-root
/// post-order traversal that writes each node's `preferred` in main/cross terms.
/// fixed contributes its given sizes, flex reports zero (it grows from free space
/// in the place pass), fit_content aggregates its already-measured children, and
/// a text leaf is measured through the cache at the proposed main extent. The
/// managed map's allocator is rebound from the stable *Tree first (Tree is
/// returned by value, so the init-time arena pointer would otherwise be stale);
/// the cache interns its key strings through that same allocator.
pub fn measure(t: *Tree, root: *Node, proposed_main: f32) std.mem.Allocator.Error!void {
    t.measure_cache.entries.allocator = t.arena.allocator();
    try measureNode(t, root, proposed_main);
}

/// Post-order over the WHOLE subtree: every node's children are measured first
/// (so any descendant fit_content is resolved before its ancestor reads it),
/// then this node's own preferred is derived from its sizing mode. The traversal
/// descends through fixed/flex containers too — a fit_content node nested under a
/// fixed parent must still be measured for the place pass to read its preference.
fn measureNode(t: *Tree, node: *Node, proposed_main: f32) std.mem.Allocator.Error!void {
    for (node.children.items) |child| try measureNode(t, child, proposed_main);

    // A text leaf sizes to its measured content. It is a childless .fit_content
    // node, so the sizing-mode switch would only yield padding before being
    // overwritten — measure it through the cache and return before the switch.
    // The place pass reads its preferred main (a .fit_content node) from here.
    if (node.text) |string| {
        const callback = node.measure_callback orelse unreachable;
        const measured = try t.measure_cache.measureCached(callback, string, proposed_main);
        node.preferred = .{ .main = measured.size.main, .cross = measured.size.cross };
        node.measure_source = measured.source;
        return;
    }

    node.preferred = switch (node.sizing_mode) {
        .fixed => .{ .main = node.main_size orelse 0, .cross = node.cross_size orelse 0 },
        .flex => .{ .main = 0, .cross = node.cross_size orelse 0 },
        .fit_content => aggregateChildren(node),
    };
}

/// fit_content aggregates the way the place pass distributes (Р11, reconciled):
/// preferred main = Σ child preferred main + (n-1)*gap + main-axis padding;
/// preferred cross = max child preferred cross + cross-axis padding. Children are
/// already measured (post-order), so a nested fit_content composes bottom-up.
fn aggregateChildren(node: *Node) PreferredSize {
    const padding = paddingExtents(node);
    if (node.children.items.len == 0) {
        return .{ .main = padding.main, .cross = padding.cross };
    }
    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    for (node.children.items) |child| {
        main_total += child.preferred.main;
        cross_max = @max(cross_max, child.preferred.cross);
    }
    const gap_count: f32 = @floatFromInt(node.children.items.len - 1);
    return .{
        .main = main_total + gap_count * node.gap + padding.main,
        .cross = cross_max + padding.cross,
    };
}

/// Per-side padding summed onto the active axes. This is the ONE site in the
/// measure pass that knows row==horizontal/column==vertical (it does not import
/// layout's AxisProjection — that would invert the inward dependency; it mirrors
/// debug.projectExtents): row's left+right is main padding, column's top+bottom.
const PaddingExtents = struct {
    main: f32,
    cross: f32,
};

fn paddingExtents(node: *Node) PaddingExtents {
    const horizontal = node.padding_left + node.padding_right;
    const vertical = node.padding_top + node.padding_bottom;
    return switch (node.direction) {
        .row => .{ .main = horizontal, .cross = vertical },
        .column => .{ .main = vertical, .cross = horizontal },
    };
}

const testing = std.testing;

/// A mock measure source standing in for the Phase 14 Core Text seam: it returns
/// a fixed main extent and a cross extent that GROWS as the proposed width
/// narrows (modeling wrap — a narrower column is taller), and counts its own
/// crossings so a test can prove the cache shields it.
const MockMeasure = struct {
    crossings: usize = 0,
    last_proposed: f32 = 0,
    fixed_main: f32,

    fn callback(self: *MockMeasure) tree.MeasureCallback {
        return .{ .context = self, .measure = measureGlyphs };
    }

    fn measureGlyphs(context: *anyopaque, text: []const u8, proposed_main: f32) MeasuredSize {
        const self: *MockMeasure = @ptrCast(@alignCast(context));
        self.crossings += 1;
        self.last_proposed = proposed_main;
        const lines = if (proposed_main <= 0) 1 else @ceil(self.fixed_main / proposed_main);
        return .{
            .main = @min(self.fixed_main, @max(proposed_main, 0)),
            .cross = @as(f32, @floatFromInt(text.len)) * lines,
        };
    }
};

fn textLeaf(t: *Tree, mock: *MockMeasure, string: []const u8) !*Node {
    const node = try t.createNode(.text);
    node.sizing_mode = .fit_content;
    node.text = string;
    node.measure_callback = mock.callback();
    return node;
}

fn fitContent(t: *Tree, direction: Direction) !*Node {
    const node = try t.createNode(.view);
    node.sizing_mode = .fit_content;
    node.direction = direction;
    return node;
}

fn fixedLeaf(t: *Tree, main_size: f32, cross_size: f32) !*Node {
    const node = try t.createNode(.view);
    node.sizing_mode = .fixed;
    node.main_size = main_size;
    node.cross_size = cross_size;
    return node;
}

test "cache hit does not re-invoke the callback for the same string and width" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 80 };

    const leaf = try textLeaf(&t, &mock, "hello");

    try measure(&t, leaf, 200);
    const first = leaf.preferred;
    try measure(&t, leaf, 200);

    try testing.expectEqual(@as(usize, 1), t.measure_cache.invocation_count);
    try testing.expectEqual(@as(usize, 1), mock.crossings);
    try testing.expectEqual(first.main, leaf.preferred.main);
    try testing.expectEqual(first.cross, leaf.preferred.cross);
}

test "the first measure crosses the seam and a repeated identical key is a cache hit that does not cross" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 80 };

    const leaf = try textLeaf(&t, &mock, "hello");

    try measure(&t, leaf, 200);
    // The first measure of a (string, width) crosses the seam and is recorded as such.
    try testing.expectEqual(MeasureSource.seam_cross, leaf.measure_source);
    try testing.expectEqual(@as(usize, 1), mock.crossings);

    try measure(&t, leaf, 200);
    // A repeated identical key is served from the cache: the provenance flips to
    // .cache_hit and the crossing counter does NOT increment (the seam is bypassed).
    try testing.expectEqual(MeasureSource.cache_hit, leaf.measure_source);
    try testing.expectEqual(@as(usize, 1), mock.crossings);
    try testing.expectEqual(@as(usize, 1), t.measure_cache.invocation_count);
}

test "distinct proposed widths are distinct keys and each crosses once" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 80 };

    const leaf = try textLeaf(&t, &mock, "hello");

    try measure(&t, leaf, 200);
    const wide = leaf.preferred;
    try measure(&t, leaf, 40);
    const narrow = leaf.preferred;

    try testing.expectEqual(@as(usize, 2), t.measure_cache.invocation_count);
    try testing.expectEqual(@as(usize, 2), mock.crossings);
    try testing.expect(narrow.cross > wide.cross);
}

test "fit_content reports summed children main plus gaps plus padding and max cross" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const container = try fitContent(&t, .row);
    container.gap = 10;
    container.padding_left = 4;
    container.padding_right = 6;
    container.padding_top = 3;
    container.padding_bottom = 5;
    const a = try fixedLeaf(&t, 30, 20);
    const b = try fixedLeaf(&t, 50, 40);
    try t.appendChild(container, a);
    try t.appendChild(container, b);

    try measure(&t, container, 0);

    try testing.expectEqual(@as(f32, 30 + 50 + 10 + 4 + 6), container.preferred.main);
    try testing.expectEqual(@as(f32, 40 + 3 + 5), container.preferred.cross);
}

test "nested fit_content composes bottom-up: outer wraps an already-wrapped inner" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const outer = try fitContent(&t, .row);
    outer.gap = 8;
    const leading = try fixedLeaf(&t, 25, 10);
    const inner = try fitContent(&t, .row);
    inner.gap = 5;
    const inner_a = try fixedLeaf(&t, 15, 12);
    const inner_b = try fixedLeaf(&t, 35, 18);
    try t.appendChild(inner, inner_a);
    try t.appendChild(inner, inner_b);
    try t.appendChild(outer, leading);
    try t.appendChild(outer, inner);

    try measure(&t, outer, 0);

    const inner_main = 15 + 35 + 5;
    try testing.expectEqual(@as(f32, inner_main), inner.preferred.main);
    try testing.expectEqual(@as(f32, 18), inner.preferred.cross);
    try testing.expectEqual(@as(f32, 25 + inner_main + 8), outer.preferred.main);
    try testing.expectEqual(@as(f32, 18), outer.preferred.cross);
}

test "the measure callback receives the proposed wrap width" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 300 };

    const leaf = try textLeaf(&t, &mock, "wrap");

    try measure(&t, leaf, 120);

    try testing.expectEqual(@as(f32, 120), mock.last_proposed);
    try testing.expectEqual(@as(f32, 120), leaf.preferred.main);
}

test "row and column fit_content mirror: padding and aggregation swap axes only" {
    var row_tree = Tree.init(testing.allocator);
    defer row_tree.deinit();
    const row_container = try fitContent(&row_tree, .row);
    row_container.gap = 10;
    row_container.padding_left = 4;
    row_container.padding_right = 6;
    row_container.padding_top = 3;
    row_container.padding_bottom = 5;
    const row_a = try fixedLeaf(&row_tree, 30, 20);
    const row_b = try fixedLeaf(&row_tree, 50, 40);
    try row_tree.appendChild(row_container, row_a);
    try row_tree.appendChild(row_container, row_b);
    try measure(&row_tree, row_container, 0);

    var column_tree = Tree.init(testing.allocator);
    defer column_tree.deinit();
    const column_container = try fitContent(&column_tree, .column);
    column_container.gap = 10;
    column_container.padding_top = 4;
    column_container.padding_bottom = 6;
    column_container.padding_left = 3;
    column_container.padding_right = 5;
    const column_a = try fixedLeaf(&column_tree, 30, 20);
    const column_b = try fixedLeaf(&column_tree, 50, 40);
    try column_tree.appendChild(column_container, column_a);
    try column_tree.appendChild(column_container, column_b);
    try measure(&column_tree, column_container, 0);

    try testing.expectEqual(row_container.preferred.main, column_container.preferred.main);
    try testing.expectEqual(row_container.preferred.cross, column_container.preferred.cross);
}

test "an empty fit_content reports only its padding" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const container = try fitContent(&t, .row);
    container.padding_left = 7;
    container.padding_right = 9;
    container.padding_top = 2;
    container.padding_bottom = 3;

    try measure(&t, container, 0);

    try testing.expectEqual(@as(f32, 16), container.preferred.main);
    try testing.expectEqual(@as(f32, 5), container.preferred.cross);
}

test "a text leaf measured size propagates to a grandparent fit_content" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var mock = MockMeasure{ .fixed_main = 60 };

    const grandparent = try fitContent(&t, .row);
    grandparent.padding_left = 5;
    grandparent.padding_right = 5;
    const parent = try fitContent(&t, .row);
    const leaf = try textLeaf(&t, &mock, "abcd");
    try t.appendChild(parent, leaf);
    try t.appendChild(grandparent, parent);

    try measure(&t, grandparent, 500);

    try testing.expectEqual(@as(f32, 60), leaf.preferred.main);
    try testing.expectEqual(@as(f32, 60), parent.preferred.main);
    try testing.expectEqual(@as(f32, 60 + 5 + 5), grandparent.preferred.main);
}
