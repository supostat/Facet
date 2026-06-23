const std = @import("std");
const tree = @import("tree.zig");
const Node = tree.Node;
const Point = tree.Point;

/// Deepest node whose absolute laid-out rect contains point, else null. The hit
/// rect IS node.layout, tested directly (coords are absolute, no offset
/// accumulation); nesting is deeper-wins, sibling overlap is last-painted-wins.
pub fn hitTest(root: *Node, point: Point) ?*Node {
    if (!containsPoint(root.layout, point)) return null;
    return deepestHit(root, point);
}

/// The half-open containment policy — left/top inclusive, right/bottom exclusive
/// — so a point on a shared edge maps to exactly one of two adjacent rects. The
/// w==0/h==0 guard documents that an unlaid/zero-size node (a default
/// LayoutResult, indistinguishable from a zero-size node at the origin) is never
/// a hit target, even at its own origin.
fn containsPoint(rect: tree.LayoutResult, point: Point) bool {
    if (rect.w == 0 or rect.h == 0) return false;
    return point.x >= rect.x and point.x < rect.x + rect.w and
        point.y >= rect.y and point.y < rect.y + rect.h;
}

/// Precondition: node.layout contains point. Descends children in reverse paint
/// order (last child painted on top → visited first); the first claiming child
/// wins (deeper-wins). If none claims it, node itself is the deepest hit
/// (miss-to-enclosing — one structural return shared by the root and deep cases).
fn deepestHit(node: *Node, point: Point) *Node {
    var index = node.children.items.len;
    while (index > 0) {
        index -= 1;
        const child = node.children.items[index];
        if (containsPoint(child.layout, point)) return deepestHit(child, point);
    }
    return node;
}

test "a point inside a single laid-out node hits that node" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 50 };

    try std.testing.expectEqual(root, hitTest(root, .{ .x = 10, .y = 10 }).?);
}

test "a point outside the root misses, and the root's own far edge is exclusive" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 50 };

    // Fully outside on the right.
    try std.testing.expectEqual(@as(?*Node, null), hitTest(root, .{ .x = 200, .y = 10 }));
    // The root's own exclusive far edge: x == x+w and y == y+h are NOT contained.
    try std.testing.expectEqual(@as(?*Node, null), hitTest(root, .{ .x = 100, .y = 50 }));
    // The inclusive near edge IS contained (the half-open entry side).
    try std.testing.expectEqual(root, hitTest(root, .{ .x = 0, .y = 0 }).?);
}

test "a point inside the root but outside every child hits the root" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const child = try t.createNode(.view);
    child.layout = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
    try t.appendChild(root, child);

    try std.testing.expectEqual(root, hitTest(root, .{ .x = 50, .y = 50 }).?);
}

test "a point inside a nested child hits the deepest child" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const middle = try t.createNode(.view);
    middle.layout = .{ .x = 10, .y = 10, .w = 80, .h = 80 };
    const leaf = try t.createNode(.view);
    leaf.layout = .{ .x = 20, .y = 20, .w = 40, .h = 40 };
    try t.appendChild(root, middle);
    try t.appendChild(middle, leaf);

    try std.testing.expectEqual(leaf, hitTest(root, .{ .x = 30, .y = 30 }).?);
    try std.testing.expectEqual(middle, hitTest(root, .{ .x = 15, .y = 15 }).?);
    try std.testing.expectEqual(root, hitTest(root, .{ .x = 5, .y = 5 }).?);
}

test "in the overlap of two siblings the later-painted (topmost) one wins" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const first = try t.createNode(.view);
    first.layout = .{ .x = 0, .y = 0, .w = 60, .h = 60 };
    const second = try t.createNode(.view);
    second.layout = .{ .x = 40, .y = 40, .w = 60, .h = 60 };
    try t.appendChild(root, first);
    try t.appendChild(root, second);

    const hit = hitTest(root, .{ .x = 50, .y = 50 }).?;
    try std.testing.expectEqual(second, hit);
    try std.testing.expect(hit != first);
}

test "a point on a shared edge of two adjacent siblings hits exactly one" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const left = try t.createNode(.view);
    left.layout = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    const right = try t.createNode(.view);
    right.layout = .{ .x = 50, .y = 0, .w = 50, .h = 50 };
    try t.appendChild(root, left);
    try t.appendChild(root, right);

    // x == 50 is the left's exclusive far edge and the right's inclusive near edge.
    const hit = hitTest(root, .{ .x = 50, .y = 25 }).?;
    try std.testing.expectEqual(right, hit);
    try std.testing.expect(hit != left);
}

test "a point in the gap between non-adjacent siblings hits the enclosing parent" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const left = try t.createNode(.view);
    left.layout = .{ .x = 0, .y = 0, .w = 30, .h = 50 };
    const right = try t.createNode(.view);
    right.layout = .{ .x = 70, .y = 0, .w = 30, .h = 50 };
    try t.appendChild(root, left);
    try t.appendChild(root, right);

    try std.testing.expectEqual(root, hitTest(root, .{ .x = 50, .y = 25 }).?);
}

test "a zero-size or unlaid child is never a hit, even at its own origin" {
    var t = tree.Tree.init(std.testing.allocator);
    defer t.deinit();

    const root = try t.createNode(.view);
    root.layout = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const unlaid = try t.createNode(.view); // default all-zero layout
    const zero_width = try t.createNode(.view);
    zero_width.layout = .{ .x = 0, .y = 0, .w = 0, .h = 50 };
    const zero_height = try t.createNode(.view);
    zero_height.layout = .{ .x = 0, .y = 0, .w = 50, .h = 0 };
    try t.appendChild(root, unlaid);
    try t.appendChild(root, zero_width);
    try t.appendChild(root, zero_height);

    const hit = hitTest(root, .{ .x = 0, .y = 0 }).?;
    try std.testing.expectEqual(root, hit);
    try std.testing.expect(hit != unlaid);
    try std.testing.expect(hit != zero_width);
    try std.testing.expect(hit != zero_height);
}
