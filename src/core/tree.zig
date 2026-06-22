const std = @import("std");
const measure = @import("measure.zig");

/// The element vocabulary of the shadow tree. A plain stored discriminant; the
/// extern-struct + comptime triple-check against the GPU Instance layout is
/// Phase 13, not here.
pub const Kind = enum { view, text };

/// How the measure pass derives a node's preferred size. EXPLICIT per node (not
/// derived from props): fixed contributes its given main_size/cross_size; flex
/// reports a zero preferred main and grows from free space in the place pass;
/// fit_content aggregates its children's preferred sizes (Р11, Ф9).
pub const SizingMode = enum { fixed, flex, fit_content };

/// A preferred size reported by the measure pass, in main/cross axis terms
/// (never width/height — Р11). A measure callback returns this shape.
pub const MeasuredSize = struct {
    main: f32,
    cross: f32,
};

/// An injected measure source for a leaf text node (Р10): the layout engine
/// hands the proposed main-axis extent (wrap width) and the callback returns the
/// resulting {main, cross} size. The function pointer keeps the platform/Core
/// Text dependency out of the Zig core; tests inject a mock, Phase 14 wires the
/// real Core Text seam. context carries the callee's state opaquely.
pub const MeasureCallback = struct {
    context: *anyopaque,
    measure: *const fn (*anyopaque, []const u8, f32) MeasuredSize,
};

/// The per-node result of the measure pass, in main/cross terms (Р11). Default
/// zero on every node so debug's per-node `preferred=` read is always defined,
/// including on flex and root nodes the measure pass leaves at zero.
pub const PreferredSize = struct {
    main: f32 = 0,
    cross: f32 = 0,
};

/// The main-axis orientation of a container's children. row lays children along
/// x (main == horizontal); column lays them along y (main == vertical). The
/// layout engine reads this and never branches on width/height directly.
pub const Direction = enum { row, column };

/// Cross-axis alignment of a child within its container's content cross extent.
/// start/center/end position a fixed cross size; stretch overrides the child's
/// cross size to the full content cross extent.
pub const Align = enum { start, center, end, stretch };

/// The layout slot reserved for Phase 8 (the layout engine fills x,y,w,h). Left
/// default-zero here; Phase 7 writes no coordinate logic.
pub const LayoutResult = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// A shadow-tree node. The prop fields mirror the GPU Instance CORE fields as
/// plain stored f32; no shadow/border/atlas fields (those join in a later
/// phase). children stores child pointers in document order.
pub const Node = struct {
    id: u32,
    kind: Kind,
    parent: ?*Node = null,
    children: std.ArrayList(*Node) = .empty,

    position_x: f32 = 0,
    position_y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    color_r: f32 = 0,
    color_g: f32 = 0,
    color_b: f32 = 0,
    color_a: f32 = 0,
    corner_radius: f32 = 0,

    // Layout-input fields (Phase 8). The layout engine reads these and writes the
    // computed rect into `layout`. width/height above stay render-only props; the
    // LAYOUT source of truth is main_size/cross_size, where null means flexible.
    direction: Direction = .row,
    gap: f32 = 0,
    padding_top: f32 = 0,
    padding_right: f32 = 0,
    padding_bottom: f32 = 0,
    padding_left: f32 = 0,
    flex_grow: f32 = 0,
    main_size: ?f32 = null,
    cross_size: ?f32 = null,
    cross_align: Align = .start,

    // Measure-input/output fields (Phase 9). sizing_mode selects how the measure
    // pass derives `preferred`; a .text node carries its string and a measure
    // callback the pass invokes through the Tree's cache. preferred defaults to
    // zero on EVERY node so debug's per-node read is defined before any measure.
    sizing_mode: SizingMode = .fixed,
    text: ?[]const u8 = null,
    measure_callback: ?MeasureCallback = null,
    preferred: PreferredSize = .{},

    layout: LayoutResult = .{},

    // Dirty-tracking fields (Phase 10). A prop mutation raises one of these per
    // the dirty classification: paint_dirty for a render-only change repainted in
    // place, layout_dirty for a geometry change re-measured/re-placed by the
    // recompute pass. Both default false on a fresh node so the debug dump's
    // per-node read is defined before any mutation; createNode applies the
    // defaults via `node.* = .{ ... }`.
    layout_dirty: bool = false,
    paint_dirty: bool = false,
};

/// A partial prop update: every field is optional, and only the non-null fields
/// are written. id/parent/children/layout are NOT updatable through this struct.
pub const PropsUpdate = struct {
    position_x: ?f32 = null,
    position_y: ?f32 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    color_r: ?f32 = null,
    color_g: ?f32 = null,
    color_b: ?f32 = null,
    color_a: ?f32 = null,
    corner_radius: ?f32 = null,
    kind: ?Kind = null,
};

/// The shadow tree. Owns an arena that backs every Node struct and each node's
/// children list storage, plus an id->*Node map. Roots are not stored in a
/// separate list: a root is any registered node with parent == null, enumerated
/// by ascending id. The map is backed by the BACKING allocator (not the arena)
/// so it can be deinit'd independently; its values are arena Nodes, so the map's
/// deinit never frees a Node and there is no double-free.
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.AutoHashMap(u32, *Node),
    measure_cache: measure.MeasureCache,
    next_id: u32,

    pub fn init(backing_allocator: std.mem.Allocator) Tree {
        var tree: Tree = .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .nodes = std.AutoHashMap(u32, *Node).init(backing_allocator),
            .measure_cache = undefined,
            .next_id = 0,
        };
        // The cache and every string it interns live in the arena, so they are
        // freed wholesale by arena.deinit() with no independent deinit (the
        // inverse of the nodes map, which is backing-allocator-owned). The arena
        // allocator captured here points at this local arena; the measure pass
        // rebinds the cache's allocator from the stable *Tree before any insert,
        // since returning Tree by value relocates the arena (createNode does the
        // same — it re-fetches self.arena.allocator() at its final address).
        tree.measure_cache = measure.MeasureCache.init(tree.arena.allocator());
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn createNode(self: *Tree, kind: Kind) std.mem.Allocator.Error!*Node {
        const node = try self.arena.allocator().create(Node);
        node.* = .{ .id = self.next_id, .kind = kind };
        try self.nodes.put(node.id, node);
        self.next_id += 1;
        return node;
    }

    pub fn lookup(self: *Tree, id: u32) ?*Node {
        return self.nodes.get(id);
    }

    pub fn appendChild(self: *Tree, parent: *Node, child: *Node) std.mem.Allocator.Error!void {
        try parent.children.append(self.arena.allocator(), child);
        child.parent = parent;
    }

    /// Inserts child immediately before anchor in parent's child list. A null
    /// anchor appends at the end. anchor MUST be a child of parent.
    pub fn insertBefore(self: *Tree, parent: *Node, child: *Node, anchor: ?*Node) std.mem.Allocator.Error!void {
        if (anchor) |anchor_node| {
            try parent.children.insert(self.arena.allocator(), childIndex(parent, anchor_node), child);
        } else {
            try parent.children.append(self.arena.allocator(), child);
        }
        child.parent = parent;
    }

    /// Detaches node from its parent (if any) and unregisters node and its whole
    /// subtree from the id map, so no removed id resolves via lookup afterwards.
    /// The node memory stays in the arena (freed wholesale at deinit); a root
    /// (parent == null) is a valid argument and skips the detach branch.
    pub fn removeNode(self: *Tree, node: *Node) void {
        if (node.parent) |parent| {
            _ = parent.children.orderedRemove(childIndex(parent, node));
            node.parent = null;
        }
        self.unregisterSubtree(node);
    }

    fn unregisterSubtree(self: *Tree, node: *Node) void {
        for (node.children.items) |child| self.unregisterSubtree(child);
        _ = self.nodes.remove(node.id);
    }

    /// The render props updateNodeProps writes, each a paint-class prop
    /// (dirty.classify), so writing any one raises paint_dirty. Named 1:1 in
    /// PropsUpdate and Node; kind is excluded because it is structural and carries
    /// no dirty flag. Every name here is asserted paint-class by the render_props
    /// lock test in dirty.zig, pinning this inline raise to the classify authority
    /// so the two paint-flag sources cannot drift.
    pub const render_props = [_][]const u8{
        "position_x", "position_y", "width",   "height",        "color_r",
        "color_g",    "color_b",    "color_a", "corner_radius",
    };

    /// Writes only the non-null fields of update; the others stay byte-untouched.
    /// Never touches layout, id, parent, or children. Writing any render prop raises
    /// paint_dirty once; kind is structural and carries no dirty flag.
    pub fn updateNodeProps(node: *Node, update: PropsUpdate) void {
        inline for (render_props) |field| {
            if (@field(update, field)) |value| {
                @field(node, field) = value;
                node.paint_dirty = true;
            }
        }
        if (update.kind) |value| node.kind = value;
    }
};

/// The index of child within parent's child list. A linear scan that hits
/// `unreachable` if child is not a child of parent: that is a caller-contract
/// violation, not a runtime condition to mask with a defensive fallback.
fn childIndex(parent: *Node, child: *Node) usize {
    for (parent.children.items, 0..) |candidate, index| {
        if (candidate == child) return index;
    }
    unreachable;
}

/// Whether a node's main-axis size is fixed and so independent of its content. The
/// SINGLE authority for the dirty-bubble stop: a fixed-main container's preferred
/// size never changes from a descendant's content, so a layout change need not
/// bubble past it. Keyed off the explicit sizing_mode (a fit_content/flex node is
/// content-dependent); the size-producing switches keep their own three-way arms.
pub fn hasFixedMainSize(node: *const Node) bool {
    return node.sizing_mode == .fixed;
}

test {
    _ = @import("debug.zig");
    _ = @import("layout.zig");
    _ = @import("measure.zig");
    _ = @import("dirty.zig");
}

test "createNode assigns sequential ids resolvable via lookup" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try tree.createNode(.view);
    const second = try tree.createNode(.text);

    try std.testing.expectEqual(@as(u32, 0), first.id);
    try std.testing.expectEqual(@as(u32, 1), second.id);
    try std.testing.expect(first.id != second.id);
    try std.testing.expectEqual(first, tree.lookup(0).?);
    try std.testing.expectEqual(second, tree.lookup(1).?);
    try std.testing.expectEqual(@as(?*Node, null), tree.lookup(2));
}

test "appendChild puts child at the end and sets its parent" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const parent = try tree.createNode(.view);
    const first = try tree.createNode(.view);
    const second = try tree.createNode(.view);

    try tree.appendChild(parent, first);
    try tree.appendChild(parent, second);

    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try std.testing.expectEqual(first, parent.children.items[0]);
    try std.testing.expectEqual(second, parent.children.items[1]);
    try std.testing.expectEqual(parent, first.parent.?);
    try std.testing.expectEqual(parent, second.parent.?);
}

test "insertBefore places the child immediately before the anchor" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const parent = try tree.createNode(.view);
    const first = try tree.createNode(.view);
    const last = try tree.createNode(.view);
    try tree.appendChild(parent, first);
    try tree.appendChild(parent, last);

    const middle = try tree.createNode(.view);
    try tree.insertBefore(parent, middle, last);

    try std.testing.expectEqual(first, parent.children.items[0]);
    try std.testing.expectEqual(middle, parent.children.items[1]);
    try std.testing.expectEqual(last, parent.children.items[2]);
    try std.testing.expectEqual(parent, middle.parent.?);
}

test "insertBefore against the first child prepends" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const parent = try tree.createNode(.view);
    const existing = try tree.createNode(.view);
    try tree.appendChild(parent, existing);

    const head = try tree.createNode(.view);
    try tree.insertBefore(parent, head, existing);

    try std.testing.expectEqual(head, parent.children.items[0]);
    try std.testing.expectEqual(existing, parent.children.items[1]);
}

test "insertBefore with a null anchor appends at the end" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const parent = try tree.createNode(.view);
    const first = try tree.createNode(.view);
    try tree.appendChild(parent, first);

    const tail = try tree.createNode(.view);
    try tree.insertBefore(parent, tail, null);

    try std.testing.expectEqual(first, parent.children.items[0]);
    try std.testing.expectEqual(tail, parent.children.items[1]);
    try std.testing.expectEqual(parent, tail.parent.?);
}

test "removeNode detaches from parent and unregisters its id" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const parent = try tree.createNode(.view);
    const keep = try tree.createNode(.view);
    const drop = try tree.createNode(.view);
    try tree.appendChild(parent, keep);
    try tree.appendChild(parent, drop);

    tree.removeNode(drop);

    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try std.testing.expectEqual(keep, parent.children.items[0]);
    try std.testing.expectEqual(@as(?*Node, null), drop.parent);
    try std.testing.expectEqual(@as(?*Node, null), tree.lookup(drop.id));
    try std.testing.expectEqual(keep, tree.lookup(keep.id).?);
}

test "removeNode unregisters every descendant in the subtree" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    const branch = try tree.createNode(.view);
    const leaf = try tree.createNode(.text);
    try tree.appendChild(root, branch);
    try tree.appendChild(branch, leaf);

    tree.removeNode(branch);

    try std.testing.expectEqual(@as(?*Node, null), tree.lookup(branch.id));
    try std.testing.expectEqual(@as(?*Node, null), tree.lookup(leaf.id));
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
    try std.testing.expectEqual(root, tree.lookup(root.id).?);
}

test "removeNode on a root unregisters it without a parent detach" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.view);
    try std.testing.expectEqual(@as(?*Node, null), root.parent);

    tree.removeNode(root);

    try std.testing.expectEqual(@as(?*Node, null), tree.lookup(root.id));
}

test "updateNodeProps writes only the named fields and leaves the rest" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const node = try tree.createNode(.view);
    node.position_x = 11;
    node.position_y = 12;
    node.width = 13;
    node.height = 14;
    node.color_r = 0.15;
    node.color_g = 0.16;
    node.color_b = 0.17;
    node.color_a = 0.18;
    node.corner_radius = 19;

    Tree.updateNodeProps(node, .{ .position_x = 3, .width = 100, .color_r = 0.5, .kind = .text });

    try std.testing.expectEqual(@as(f32, 3), node.position_x);
    try std.testing.expectEqual(@as(f32, 100), node.width);
    try std.testing.expectEqual(@as(f32, 0.5), node.color_r);
    try std.testing.expectEqual(Kind.text, node.kind);
    try std.testing.expectEqual(@as(f32, 12), node.position_y);
    try std.testing.expectEqual(@as(f32, 14), node.height);
    try std.testing.expectEqual(@as(f32, 0.16), node.color_g);
    try std.testing.expectEqual(@as(f32, 0.17), node.color_b);
    try std.testing.expectEqual(@as(f32, 0.18), node.color_a);
    try std.testing.expectEqual(@as(f32, 19), node.corner_radius);
    try std.testing.expectEqual(@as(f32, 0), node.layout.x);
    try std.testing.expect(node.paint_dirty);
}

test "updateNodeProps with an all-null update is a no-op" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const node = try tree.createNode(.view);
    node.position_x = 42;

    Tree.updateNodeProps(node, .{});

    try std.testing.expectEqual(@as(f32, 42), node.position_x);
    try std.testing.expectEqual(Kind.view, node.kind);
    try std.testing.expect(!node.paint_dirty);
}
