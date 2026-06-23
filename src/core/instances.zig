const std = @import("std");
const tree = @import("tree.zig");
const Node = tree.Node;
const Tree = tree.Tree;
const PlacedGlyph = tree.PlacedGlyph;

/// The kind of primitive an Instance describes (Р13). The raw value is the
/// discriminant shared VERBATIM with the Swift `enum InstanceType: UInt32` and
/// the MSL `type == 1u` branch in sdf.metal: sdf_rounded_rect selects the SDF
/// fill/shadow/border path, glyph the atlas-sampling path. Both kinds draw in one
/// instanced pass, distinguished only by this tag.
pub const InstanceType = enum(u32) {
    sdf_rounded_rect = 0,
    glyph = 1,
};

/// One GPU instance: a flat, behavior-free value with a fixed C-compatible field
/// order. This Zig `extern struct` is the SOURCE OF TRUTH for the Р13 binary
/// contract; src/platform/Instance.swift and src/shaders/sdf.metal mirror it
/// field-for-field (NAMES, TYPES, ORDER). 25 f32 plus one u32 (`type` at field
/// index 9, byte offset 36) gives a 104-byte stride with no trailing padding, so
/// the array uploads as a packed buffer (verified: @sizeOf == 104,
/// @offsetOf(type) == 36). Geometry is in drawable pixels, top-left origin;
/// positionX/Y is the rect CENTER, width/height the full extent; color and
/// shadowColor are straight-alpha RGBA in [0, 1]. Inert defaults (shadow 0,
/// border 0, atlas rect 0) reduce an SDF instance to the body fill and never take
/// the glyph branch. For a glyph instance the atlasMin/Max U/V name the glyph's
/// sub-rectangle in [0, 1] atlas coordinates and color tints the R8 coverage.
///
/// Field names are camelCase — a DELIBERATE, documented deviation from Zig
/// snake_case honoring the Р13 "field names identical across Zig/Swift/MSL"
/// invariant (Swift + MSL are camelCase). `type` is a plain field accessed as
/// `.type` (no @"type" escape needed in Zig 0.15.2). The comptime triple-check
/// against the Swift/MSL layout is Phase 13; appends here are append-only.
pub const Instance = extern struct {
    positionX: f32,
    positionY: f32,
    width: f32,
    height: f32,
    colorR: f32,
    colorG: f32,
    colorB: f32,
    colorA: f32,
    cornerRadius: f32,
    type: u32,
    shadowOffsetX: f32,
    shadowOffsetY: f32,
    shadowBlurRadius: f32,
    shadowColorR: f32,
    shadowColorG: f32,
    shadowColorB: f32,
    shadowColorA: f32,
    borderThickness: f32,
    borderColorR: f32,
    borderColorG: f32,
    borderColorB: f32,
    borderColorA: f32,
    atlasMinU: f32,
    atlasMinV: f32,
    atlasMaxU: f32,
    atlasMaxV: f32,
};

/// The contiguous span a node owns in the instance buffer: count consecutive
/// instances starting at start. A .view node owns exactly one; a .text node owns
/// one per placed glyph (count 0 for empty text). The producer keeps an id→range
/// side map so a paint-only change rewrites exactly that span in place.
pub const SlotRange = struct {
    start: u32,
    count: u32,
};

/// Builds and owns the flat []Instance the renderer uploads, plus a stable
/// id→SlotRange side map. The buffer and map live on a STORED backing allocator,
/// NOT the Tree arena: the arena never reclaims per-allocation, so a per-frame
/// rebuild into it would leak; a self-owned buffer decouples the producer's
/// lifecycle from the tree's (mirroring the shadow-tree's separately-backed id
/// map). build() does a full pre-order DFS rebuild; pointUpdate() rewrites one
/// node's span in place for a paint-only change.
pub const InstanceProducer = struct {
    backing_allocator: std.mem.Allocator,
    instances: std.ArrayList(Instance) = .empty,
    slots: std.AutoHashMap(u32, SlotRange),

    pub fn init(backing_allocator: std.mem.Allocator) InstanceProducer {
        return .{
            .backing_allocator = backing_allocator,
            .slots = std.AutoHashMap(u32, SlotRange).init(backing_allocator),
        };
    }

    /// Frees the producer-owned buffer and map. Takes NO Tree argument: the
    /// producer owns its storage, so this is independent of tree.deinit().
    pub fn deinit(self: *InstanceProducer) void {
        self.instances.deinit(self.backing_allocator);
        self.slots.deinit();
        self.* = undefined;
    }

    /// Full rebuild: clears the buffer and map, then pre-order DFS-appends from
    /// root (parent before child = forward paint order). Only READS the tree.
    pub fn build(self: *InstanceProducer, root: *Node) std.mem.Allocator.Error!void {
        self.instances.clearRetainingCapacity();
        self.slots.clearRetainingCapacity();
        try self.emit(root);
    }

    /// Pre-order: emit this node's own instances (recording its slot), then
    /// recurse into children. An invisible node emits nothing and records no
    /// slot, but the walk STILL descends into its children.
    fn emit(self: *InstanceProducer, node: *Node) std.mem.Allocator.Error!void {
        if (visible(node)) {
            const start: u32 = @intCast(self.instances.items.len);
            switch (node.kind) {
                .view => try self.instances.append(self.backing_allocator, sdfInstance(node)),
                .text => for (placedGlyphs(node)) |glyph| {
                    try self.instances.append(self.backing_allocator, glyphInstance(node, glyph));
                },
            }
            const count: u32 = @intCast(self.instances.items.len - start);
            try self.slots.put(node.id, .{ .start = start, .count = count });
        }
        for (node.children.items) |child| try self.emit(child);
    }

    /// Rewrites the node's already-sized span in place from its current props
    /// (a paint-only change re-tints/repositions the same geometry without a
    /// rebuild), then clears paint_dirty. The node MUST have been emitted (its
    /// span exists and the glyph count is unchanged — a paint change never adds
    /// or drops glyphs).
    pub fn pointUpdate(self: *InstanceProducer, node: *Node) void {
        // A node that was zero-size (invisible) at the last build() emitted no
        // instance and recorded no slot, so a paint-dirty flag on it has nothing
        // to repaint: clear the flag and return (a no-op repaint of a non-drawn
        // node, not a masked bug — keeps an invisible node from staying dirty).
        const range = self.slots.get(node.id) orelse {
            node.paint_dirty = false;
            return;
        };
        switch (node.kind) {
            .view => self.instances.items[range.start] = sdfInstance(node),
            .text => {
                const glyphs = placedGlyphs(node);
                // A glyph-count change is structural (layout_dirty → full
                // rebuild), so a paint-only path NEVER alters the count: a
                // mismatch means a layout change was mis-routed as paint.
                std.debug.assert(glyphs.len == range.count);
                for (glyphs, 0..) |glyph, offset| {
                    self.instances.items[range.start + offset] = glyphInstance(node, glyph);
                }
            },
        }
        node.paint_dirty = false;
    }

    /// The packed instance buffer the renderer uploads (the Р13 pointer+length
    /// view), valid until the next build().
    pub fn slice(self: *const InstanceProducer) []const Instance {
        return self.instances.items;
    }
};

/// Whether a node contributes instances: a degenerate (zero-area) rect draws
/// nothing, so it is skipped (mirrors hit_test.zig's w==0/h==0 guard). Per-node
/// only — the DFS still recurses into a zero-size node's children.
fn visible(node: *const Node) bool {
    return node.layout.w != 0 and node.layout.h != 0;
}

fn placedGlyphs(node: *const Node) []const PlacedGlyph {
    return node.placed_glyphs orelse &.{};
}

/// The SDF instance for a .view node: the laid-out rect is TOP-LEFT
/// (layout.{x,y,w,h}) but Instance.position is the rect CENTER, so the center is
/// the top-left plus half the extent. Color/cornerRadius/shadow/border come from
/// the node's render props; the atlas rect is inert (the glyph branch is never
/// taken).
fn sdfInstance(node: *const Node) Instance {
    return .{
        .positionX = node.layout.x + node.layout.w / 2,
        .positionY = node.layout.y + node.layout.h / 2,
        .width = node.layout.w,
        .height = node.layout.h,
        .colorR = node.color_r,
        .colorG = node.color_g,
        .colorB = node.color_b,
        .colorA = node.color_a,
        .cornerRadius = node.corner_radius,
        .type = @intFromEnum(InstanceType.sdf_rounded_rect),
        .shadowOffsetX = node.shadow_offset_x,
        .shadowOffsetY = node.shadow_offset_y,
        .shadowBlurRadius = node.shadow_blur_radius,
        .shadowColorR = node.shadow_color_r,
        .shadowColorG = node.shadow_color_g,
        .shadowColorB = node.shadow_color_b,
        .shadowColorA = node.shadow_color_a,
        .borderThickness = node.border_thickness,
        .borderColorR = node.border_color_r,
        .borderColorG = node.border_color_g,
        .borderColorB = node.border_color_b,
        .borderColorA = node.border_color_a,
        .atlasMinU = 0,
        .atlasMinV = 0,
        .atlasMaxU = 0,
        .atlasMaxV = 0,
    };
}

/// The glyph instance for one placed glyph of a .text node: the cell center and
/// size are consumed VERBATIM from the glyph (bearing already baked at Phase 6),
/// the node's color tints the R8 coverage, and the atlas sub-rect names the
/// glyph in the texture. cornerRadius/shadow/border are inert (the SDF path is
/// never taken).
fn glyphInstance(node: *const Node, glyph: PlacedGlyph) Instance {
    return .{
        .positionX = glyph.center_x,
        .positionY = glyph.center_y,
        .width = glyph.width,
        .height = glyph.height,
        .colorR = node.color_r,
        .colorG = node.color_g,
        .colorB = node.color_b,
        .colorA = node.color_a,
        .cornerRadius = 0,
        .type = @intFromEnum(InstanceType.glyph),
        .shadowOffsetX = 0,
        .shadowOffsetY = 0,
        .shadowBlurRadius = 0,
        .shadowColorR = 0,
        .shadowColorG = 0,
        .shadowColorB = 0,
        .shadowColorA = 0,
        .borderThickness = 0,
        .borderColorR = 0,
        .borderColorG = 0,
        .borderColorB = 0,
        .borderColorA = 0,
        .atlasMinU = glyph.atlas_min_u,
        .atlasMinV = glyph.atlas_min_v,
        .atlasMaxU = glyph.atlas_max_u,
        .atlasMaxV = glyph.atlas_max_v,
    };
}

/// Every float in the machine dump renders with this format: locale-independent
/// and byte-deterministic across runs (mirrors debug.zig's FLOAT_FORMAT).
const FLOAT_FORMAT = "{d:.4}";

/// Dumps the instance buffer and node→slot map to writer. The machine form
/// (pretty == false) is a single deterministic line per slot plus the map, in a
/// fixed field order, byte-deterministic across runs; the pretty form reuses the
/// SAME collection (no second collector) and is free of the byte-determinism
/// contract. Lives HERE, not in debug.zig, because the inward rule forbids
/// debug.zig (which imports only tree) from depending on instances.
pub fn dump(producer: *const InstanceProducer, tree_handle: *Tree, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    for (producer.instances.items, 0..) |instance, index| {
        try writeSlot(producer, index, instance, writer, pretty);
    }
    try writeMap(producer, tree_handle, writer, pretty);
}

fn writeSlot(producer: *const InstanceProducer, index: usize, instance: Instance, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    const owner = ownerId(producer, @intCast(index));
    if (pretty) try writer.writeAll("  ");
    try writer.print("slot {d} node={d} type={s}", .{ index, owner, @tagName(@as(InstanceType, @enumFromInt(instance.type))) });
    try writer.print(" pos=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ instance.positionX, instance.positionY });
    try writer.print(" size=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ instance.width, instance.height });
    try writer.print(" color=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ instance.colorR, instance.colorG, instance.colorB, instance.colorA });
    try writer.print(" radius=" ++ FLOAT_FORMAT, .{instance.cornerRadius});
    try writer.print(" shadow=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ instance.shadowOffsetX, instance.shadowOffsetY, instance.shadowBlurRadius, instance.shadowColorR, instance.shadowColorG, instance.shadowColorB, instance.shadowColorA });
    try writer.print(" border=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT, .{ instance.borderThickness, instance.borderColorR, instance.borderColorG, instance.borderColorB, instance.borderColorA });
    try writer.print(" atlas=" ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "," ++ FLOAT_FORMAT ++ "\n", .{ instance.atlasMinU, instance.atlasMinV, instance.atlasMaxU, instance.atlasMaxV });
}

/// Enumerates the node→slot map by ASCENDING node id (0..next_id, skipping
/// unmapped ids) — NOT hash-map iteration order — so the dump is deterministic.
fn writeMap(producer: *const InstanceProducer, tree_handle: *Tree, writer: *std.Io.Writer, pretty: bool) std.Io.Writer.Error!void {
    var id: u32 = 0;
    while (id < tree_handle.next_id) : (id += 1) {
        const range = producer.slots.get(id) orelse continue;
        if (pretty) try writer.writeAll("  ");
        try writer.print("map node={d} start={d} count={d}\n", .{ id, range.start, range.count });
    }
}

/// The id of the node owning the slot at index: the single range covering it.
/// Every slot is covered by construction, so a miss is a contract violation
/// (`unreachable` — a checked panic in the .Debug core).
fn ownerId(producer: *const InstanceProducer, index: u32) u32 {
    var iterator = producer.slots.iterator();
    while (iterator.next()) |entry| {
        const range = entry.value_ptr.*;
        if (index >= range.start and index < range.start + range.count) return entry.key_ptr.*;
    }
    unreachable;
}

const testing = std.testing;

/// Renders the instance dump into an owned slice via the testing allocator
/// (caller frees). Mirrors layout.zig's renderFailureTrace.
fn renderInstanceTrace(producer: *const InstanceProducer, tree_handle: *Tree) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer sink.deinit();
    try dump(producer, tree_handle, &sink.writer, false);
    return sink.toOwnedSlice();
}

/// Attaches the instance dump on a test failure path (mirrors layout.zig's
/// printLayoutTraceOnFailure): wired into the assertion-bearing tests via
/// errdefer so a drifted field localizes to a slot and its owning node.
fn printInstancesOnFailure(producer: *const InstanceProducer, tree_handle: *Tree) void {
    const trace = renderInstanceTrace(producer, tree_handle) catch return;
    defer testing.allocator.free(trace);
    std.debug.print("\ninstance dump at failure:\n{s}", .{trace});
}

/// A fixed mock view node at an absolute rect with a solid color — the test
/// fixture for the SDF path (layout written directly, no layout pass).
fn viewNode(t: *Tree, rect: tree.LayoutResult, color: [4]f32) !*Node {
    const node = try t.createNode(.view);
    node.layout = rect;
    node.color_r = color[0];
    node.color_g = color[1];
    node.color_b = color[2];
    node.color_a = color[3];
    return node;
}

/// A mock text node sized to a visible rect, carrying arena-allocated placed
/// glyphs (the Phase 6 seam is mocked — never real Core Text). The slice lives
/// in the Tree arena so it frees with the tree.
fn textNode(t: *Tree, rect: tree.LayoutResult, color: [4]f32, glyphs: []const PlacedGlyph) !*Node {
    const node = try t.createNode(.text);
    node.layout = rect;
    node.color_r = color[0];
    node.color_g = color[1];
    node.color_b = color[2];
    node.color_a = color[3];
    node.placed_glyphs = try t.arena.allocator().dupe(PlacedGlyph, glyphs);
    return node;
}

test "a known view tree builds the exact instance array with top-left rects as centers" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    const root = try viewNode(&t, .{ .x = 10, .y = 20, .w = 200, .h = 100 }, .{ 0.1, 0.2, 0.3, 1.0 });
    root.corner_radius = 8;
    root.shadow_offset_x = 4;
    root.shadow_blur_radius = 12;
    root.shadow_color_a = 0.5;
    root.border_thickness = 2;
    root.border_color_r = 1;
    root.border_color_a = 1;

    try producer.build(root);
    errdefer printInstancesOnFailure(&producer, &t);

    try testing.expectEqual(@as(usize, 1), producer.slice().len);
    const expected = Instance{
        .positionX = 110, .positionY = 70, .width = 200, .height = 100,
        .colorR = 0.1, .colorG = 0.2, .colorB = 0.3, .colorA = 1.0,
        .cornerRadius = 8, .type = 0,
        .shadowOffsetX = 4, .shadowOffsetY = 0, .shadowBlurRadius = 12,
        .shadowColorR = 0, .shadowColorG = 0, .shadowColorB = 0, .shadowColorA = 0.5,
        .borderThickness = 2, .borderColorR = 1, .borderColorG = 0, .borderColorB = 0, .borderColorA = 1,
        .atlasMinU = 0, .atlasMinV = 0, .atlasMaxU = 0, .atlasMaxV = 0,
    };
    try testing.expectEqual(expected, producer.slice()[0]);
}

test "a view parent with a text child emits one SDF then one glyph per placed glyph in DFS order" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    const root = try viewNode(&t, .{ .x = 0, .y = 0, .w = 300, .h = 80 }, .{ 0.9, 0.9, 0.9, 1.0 });
    const label = try textNode(&t, .{ .x = 8, .y = 8, .w = 64, .h = 18 }, .{ 0, 0, 0, 1 }, &.{
        .{ .center_x = 12, .center_y = 17, .width = 10, .height = 14, .atlas_min_u = 0.1, .atlas_min_v = 0.2, .atlas_max_u = 0.15, .atlas_max_v = 0.3 },
        .{ .center_x = 24, .center_y = 17, .width = 10, .height = 14, .atlas_min_u = 0.2, .atlas_min_v = 0.2, .atlas_max_u = 0.25, .atlas_max_v = 0.3 },
        .{ .center_x = 36, .center_y = 17, .width = 10, .height = 14, .atlas_min_u = 0.3, .atlas_min_v = 0.2, .atlas_max_u = 0.35, .atlas_max_v = 0.3 },
    });
    try t.appendChild(root, label);

    try producer.build(root);
    errdefer printInstancesOnFailure(&producer, &t);

    const instances = producer.slice();
    try testing.expectEqual(@as(usize, 4), instances.len);
    try testing.expectEqual(@as(u32, @intFromEnum(InstanceType.sdf_rounded_rect)), instances[0].type);
    try testing.expectEqual(@as(u32, @intFromEnum(InstanceType.glyph)), instances[1].type);
    try testing.expectEqual(@as(u32, @intFromEnum(InstanceType.glyph)), instances[2].type);
    try testing.expectEqual(@as(u32, @intFromEnum(InstanceType.glyph)), instances[3].type);
    // The glyph carries the placed center verbatim and the node's color as the tint.
    try testing.expectEqual(@as(f32, 24), instances[2].positionX);
    try testing.expectEqual(@as(f32, 0.2), instances[2].atlasMinU);
    try testing.expectEqual(@as(f32, 1), instances[1].colorA);
    // The inert-field contrast is local: a glyph slot zeroes the SDF-only fields,
    // mirroring the SDF slot zeroing the atlas rect.
    try testing.expectEqual(@as(f32, 0), instances[1].cornerRadius);
    try testing.expectEqual(@as(f32, 0), instances[1].shadowColorA);
    try testing.expectEqual(@as(f32, 0), instances[1].borderThickness);
    try testing.expectEqual(@as(f32, 0), instances[0].atlasMaxU);
    try testing.expectEqual(SlotRange{ .start = 0, .count = 1 }, producer.slots.get(root.id).?);
    try testing.expectEqual(SlotRange{ .start = 1, .count = 3 }, producer.slots.get(label.id).?);
}

test "a paint-dirty view rewrites exactly its slot, leaves every other byte identical, and clears the flag" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    const root = try viewNode(&t, .{ .x = 0, .y = 0, .w = 100, .h = 50 }, .{ 1, 0, 0, 1 });
    const sibling = try viewNode(&t, .{ .x = 0, .y = 50, .w = 100, .h = 50 }, .{ 0, 1, 0, 1 });
    try t.appendChild(root, sibling);

    try producer.build(root);
    errdefer printInstancesOnFailure(&producer, &t);

    const before = try testing.allocator.dupe(Instance, producer.slice());
    defer testing.allocator.free(before);

    sibling.color_b = 0.5;
    sibling.paint_dirty = true;
    producer.pointUpdate(sibling);

    const after = producer.slice();
    const sibling_slot = producer.slots.get(sibling.id).?.start;
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&before[sibling_slot]), std.mem.asBytes(&after[sibling_slot])));
    try testing.expectEqual(@as(f32, 0.5), after[sibling_slot].colorB);
    // Every OTHER slot is byte-for-byte unchanged.
    for (before, after, 0..) |old, new, index| {
        if (index == sibling_slot) continue;
        try testing.expect(std.mem.eql(u8, std.mem.asBytes(&old), std.mem.asBytes(&new)));
    }
    try testing.expect(!sibling.paint_dirty);
}

test "the node-to-slot map is stable across two full rebuilds of the same tree" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    const root = try viewNode(&t, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .{ 0.5, 0.5, 0.5, 1 });
    const a = try viewNode(&t, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ 1, 0, 0, 1 });
    const b = try textNode(&t, .{ .x = 40, .y = 0, .w = 30, .h = 18 }, .{ 0, 0, 0, 1 }, &.{
        .{ .center_x = 45, .center_y = 9, .width = 8, .height = 12, .atlas_min_u = 0, .atlas_min_v = 0, .atlas_max_u = 0.1, .atlas_max_v = 0.1 },
        .{ .center_x = 55, .center_y = 9, .width = 8, .height = 12, .atlas_min_u = 0.1, .atlas_min_v = 0, .atlas_max_u = 0.2, .atlas_max_v = 0.1 },
    });
    try t.appendChild(root, a);
    try t.appendChild(root, b);

    try producer.build(root);
    const first_root = producer.slots.get(root.id).?;
    const first_a = producer.slots.get(a.id).?;
    const first_b = producer.slots.get(b.id).?;

    try producer.build(root);
    try testing.expectEqual(first_root, producer.slots.get(root.id).?);
    try testing.expectEqual(first_a, producer.slots.get(a.id).?);
    try testing.expectEqual(first_b, producer.slots.get(b.id).?);
}

test "a zero-size node emits no instance but the DFS still recurses into its visible child" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    // Zero-size parent: no slot, no instance, but its child is still walked.
    const invisible_parent = try viewNode(&t, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .{ 1, 1, 1, 1 });
    const visible_child = try viewNode(&t, .{ .x = 0, .y = 0, .w = 50, .h = 50 }, .{ 0, 0, 1, 1 });
    try t.appendChild(invisible_parent, visible_child);

    // A separately visible root holding a zero-width and zero-height leaf, both skipped.
    const zero_width = try viewNode(&t, .{ .x = 0, .y = 0, .w = 0, .h = 50 }, .{ 1, 0, 0, 1 });
    const zero_height = try viewNode(&t, .{ .x = 0, .y = 0, .w = 50, .h = 0 }, .{ 0, 1, 0, 1 });
    try t.appendChild(visible_child, zero_width);
    try t.appendChild(visible_child, zero_height);

    try producer.build(invisible_parent);

    try testing.expectEqual(@as(usize, 1), producer.slice().len);
    try testing.expectEqual(@as(?SlotRange, null), producer.slots.get(invisible_parent.id));
    try testing.expectEqual(@as(?SlotRange, null), producer.slots.get(zero_width.id));
    try testing.expectEqual(@as(?SlotRange, null), producer.slots.get(zero_height.id));
    try testing.expectEqual(SlotRange{ .start = 0, .count = 1 }, producer.slots.get(visible_child.id).?);
}

test "a static frame needs no rebuild and a paint-only update rewrites only the dirty slot" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    const root = try viewNode(&t, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .{ 0.2, 0.2, 0.2, 1 });
    const first = try viewNode(&t, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ 1, 0, 0, 1 });
    const second = try viewNode(&t, .{ .x = 40, .y = 0, .w = 40, .h = 40 }, .{ 0, 1, 0, 1 });
    try t.appendChild(root, first);
    try t.appendChild(root, second);

    try producer.build(root);
    const snapshot = try testing.allocator.dupe(Instance, producer.slice());
    defer testing.allocator.free(snapshot);

    // No prop changed → re-reading the slice yields the same bytes (no rebuild needed).
    try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(snapshot), std.mem.sliceAsBytes(producer.slice())));

    // A single paint-only change rewrites ONLY that node's slot.
    first.color_r = 0.25;
    first.paint_dirty = true;
    producer.pointUpdate(first);

    const first_slot = producer.slots.get(first.id).?.start;
    const second_slot = producer.slots.get(second.id).?.start;
    const root_slot = producer.slots.get(root.id).?.start;
    try testing.expectEqual(@as(f32, 0.25), producer.slice()[first_slot].colorR);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&snapshot[second_slot]), std.mem.asBytes(&producer.slice()[second_slot])));
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&snapshot[root_slot]), std.mem.asBytes(&producer.slice()[root_slot])));
}

test "a sized text node with no placed glyphs emits no instance but records a zero-count slot" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    // A non-zero layout (so visible() passes) but an EMPTY glyph slice: the node
    // owns a span of zero instances, distinct from an unmapped invisible node.
    const empty_label = try textNode(&t, .{ .x = 4, .y = 4, .w = 40, .h = 18 }, .{ 0, 0, 0, 1 }, &.{});

    try producer.build(empty_label);
    errdefer printInstancesOnFailure(&producer, &t);

    try testing.expectEqual(@as(usize, 0), producer.slice().len);
    try testing.expectEqual(SlotRange{ .start = 0, .count = 0 }, producer.slots.get(empty_label.id).?);
}

test "a paint-dirty text node re-tints all its glyph slots and leaves every other byte identical" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    const root = try viewNode(&t, .{ .x = 0, .y = 0, .w = 200, .h = 60 }, .{ 0.5, 0.5, 0.5, 1 });
    const label = try textNode(&t, .{ .x = 8, .y = 8, .w = 40, .h = 18 }, .{ 0, 0, 0, 1 }, &.{
        .{ .center_x = 12, .center_y = 17, .width = 10, .height = 14, .atlas_min_u = 0.1, .atlas_min_v = 0.2, .atlas_max_u = 0.15, .atlas_max_v = 0.3 },
        .{ .center_x = 24, .center_y = 17, .width = 10, .height = 14, .atlas_min_u = 0.2, .atlas_min_v = 0.2, .atlas_max_u = 0.25, .atlas_max_v = 0.3 },
    });
    try t.appendChild(root, label);

    try producer.build(root);
    errdefer printInstancesOnFailure(&producer, &t);

    const before = try testing.allocator.dupe(Instance, producer.slice());
    defer testing.allocator.free(before);

    label.color_r = 0.75;
    label.paint_dirty = true;
    producer.pointUpdate(label);

    const after = producer.slice();
    const label_range = producer.slots.get(label.id).?;
    // Every glyph slot the text node owns is re-tinted; geometry and atlas rect
    // are rewritten verbatim from the unchanged glyphs, so only color moves.
    for (label_range.start..label_range.start + label_range.count) |slot| {
        try testing.expectEqual(@as(f32, 0.75), after[slot].colorR);
        try testing.expectEqual(before[slot].positionX, after[slot].positionX);
        try testing.expectEqual(before[slot].atlasMinU, after[slot].atlasMinU);
    }
    // Every slot OUTSIDE the text node's span is byte-for-byte unchanged.
    for (before, after, 0..) |old, new, index| {
        if (index >= label_range.start and index < label_range.start + label_range.count) continue;
        try testing.expect(std.mem.eql(u8, std.mem.asBytes(&old), std.mem.asBytes(&new)));
    }
    try testing.expect(!label.paint_dirty);
}

test "the machine dump is byte-deterministic, the pretty form carries the same values, and the map is ascending-id" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var producer = InstanceProducer.init(testing.allocator);
    defer producer.deinit();

    const root = try viewNode(&t, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .{ 0.5, 0.6, 0.7, 1 });
    const label = try textNode(&t, .{ .x = 0, .y = 0, .w = 30, .h = 18 }, .{ 0, 0, 0, 1 }, &.{
        .{ .center_x = 10, .center_y = 9, .width = 8, .height = 12, .atlas_min_u = 0.1, .atlas_min_v = 0.2, .atlas_max_u = 0.15, .atlas_max_v = 0.3 },
    });
    try t.appendChild(root, label);

    try producer.build(root);

    const machine_first = try renderInstanceTrace(&producer, &t);
    defer testing.allocator.free(machine_first);
    const machine_second = try renderInstanceTrace(&producer, &t);
    defer testing.allocator.free(machine_second);
    try testing.expectEqualStrings(machine_first, machine_second);

    const expected =
        "slot 0 node=0 type=sdf_rounded_rect pos=100.0000,50.0000 size=200.0000,100.0000 color=0.5000,0.6000,0.7000,1.0000 radius=0.0000 shadow=0.0000,0.0000,0.0000,0.0000,0.0000,0.0000,0.0000 border=0.0000,0.0000,0.0000,0.0000,0.0000 atlas=0.0000,0.0000,0.0000,0.0000\n" ++
        "slot 1 node=1 type=glyph pos=10.0000,9.0000 size=8.0000,12.0000 color=0.0000,0.0000,0.0000,1.0000 radius=0.0000 shadow=0.0000,0.0000,0.0000,0.0000,0.0000,0.0000,0.0000 border=0.0000,0.0000,0.0000,0.0000,0.0000 atlas=0.1000,0.2000,0.1500,0.3000\n" ++
        "map node=0 start=0 count=1\n" ++
        "map node=1 start=1 count=1\n";
    try testing.expectEqualStrings(expected, machine_first);

    var pretty_sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer pretty_sink.deinit();
    try dump(&producer, &t, &pretty_sink.writer, true);
    const pretty = pretty_sink.written();
    try testing.expect(std.mem.indexOf(u8, pretty, "type=sdf_rounded_rect pos=100.0000,50.0000") != null);
    try testing.expect(std.mem.indexOf(u8, pretty, "type=glyph pos=10.0000,9.0000") != null);
    try testing.expect(std.mem.indexOf(u8, pretty, "atlas=0.1000,0.2000,0.1500,0.3000") != null);
}
