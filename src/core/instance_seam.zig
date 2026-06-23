const std = @import("std");
const tree = @import("tree.zig");
const layout = @import("layout.zig");
const dirty = @import("dirty.zig");
const hit_test = @import("hit_test.zig");
const instances = @import("instances.zig");
const Tree = tree.Tree;
const Node = tree.Node;
const Instance = instances.Instance;
const InstanceProducer = instances.InstanceProducer;
const ExternalTarget = instances.ExternalTarget;

// instance_seam.zig is the OUTERMOST core module: the only .zig that imports
// layout/dirty/hit_test/instances/tree together, and the only one carrying
// callconv(.c) exports. It is the Zig side of the Р13 lower seam — Swift hands it
// a StorageModeShared MTLBuffer base pointer and the seam writes the instance
// array straight into that GPU-visible memory (zero-copy via unified memory).
// Nothing inside core imports this file; the Dependency Rule permits an outer
// consumer to import inward.

/// The frozen byte offset of every Instance field, the Р13 source-of-truth layout
/// the Swift FacetInstance C struct and the MSL `struct Instance` mirror. Every
/// field is 4 bytes (25 f32 + one u32 `type` at index 9) with no padding, so the
/// offsets run 0, 4, 8, … 100 and the stride is 104. A reorder or insertion moves
/// one of these and fails the comptime assertion AND the layout test below — the
/// build and `zig build test` both break on drift, so the three languages cannot
/// silently desync.
const ExpectedOffset = struct {
    name: []const u8,
    offset: comptime_int,
};

const expected_offsets = [_]ExpectedOffset{
    .{ .name = "positionX", .offset = 0 },
    .{ .name = "positionY", .offset = 4 },
    .{ .name = "width", .offset = 8 },
    .{ .name = "height", .offset = 12 },
    .{ .name = "colorR", .offset = 16 },
    .{ .name = "colorG", .offset = 20 },
    .{ .name = "colorB", .offset = 24 },
    .{ .name = "colorA", .offset = 28 },
    .{ .name = "cornerRadius", .offset = 32 },
    .{ .name = "type", .offset = 36 },
    .{ .name = "shadowOffsetX", .offset = 40 },
    .{ .name = "shadowOffsetY", .offset = 44 },
    .{ .name = "shadowBlurRadius", .offset = 48 },
    .{ .name = "shadowColorR", .offset = 52 },
    .{ .name = "shadowColorG", .offset = 56 },
    .{ .name = "shadowColorB", .offset = 60 },
    .{ .name = "shadowColorA", .offset = 64 },
    .{ .name = "borderThickness", .offset = 68 },
    .{ .name = "borderColorR", .offset = 72 },
    .{ .name = "borderColorG", .offset = 76 },
    .{ .name = "borderColorB", .offset = 80 },
    .{ .name = "borderColorA", .offset = 84 },
    .{ .name = "atlasMinU", .offset = 88 },
    .{ .name = "atlasMinV", .offset = 92 },
    .{ .name = "atlasMaxU", .offset = 96 },
    .{ .name = "atlasMaxV", .offset = 100 },
};

/// The frozen stride and alignment of the Р13 contract. 104-byte stride, 4-byte
/// alignment (the widest member is a 4-byte scalar), no trailing padding.
const EXPECTED_STRIDE = 104;
const EXPECTED_ALIGNMENT = 4;

/// Compile-time triple-check of the Instance layout against the frozen table: the
/// stride, the alignment, the field count, and every field's byte offset. This
/// runs at BUILD time (referenced from the exports below), so a drifted layout
/// fails the static lib compile, not just `zig build test`.
fn assertInstanceLayout() void {
    comptime {
        std.debug.assert(@sizeOf(Instance) == EXPECTED_STRIDE);
        std.debug.assert(@alignOf(Instance) == EXPECTED_ALIGNMENT);
        std.debug.assert(@typeInfo(Instance).@"struct".fields.len == expected_offsets.len);
        for (expected_offsets) |entry| {
            std.debug.assert(@offsetOf(Instance, entry.name) == entry.offset);
        }
    }
}

comptime {
    assertInstanceLayout();
}

/// The opaque seam handle Swift holds as a `*anyopaque`. It owns the shadow tree,
/// the instance producer, and the current external target, plus the epoch
/// counters that drive has-changed. Created and destroyed through the C exports;
/// the explicit handle (not a module global) keeps independent seams — the КТ-2
/// harness and the e2e test each own one — from sharing hidden state.
const Seam = struct {
    gpa: std.mem.Allocator,
    tree: Tree,
    producer: InstanceProducer,
    root: ?*Node,
    target: ?ExternalTarget,
    /// Bumped on every tree mutation (build-reference, paint mutation). The frame
    /// loop compares it to last_produced_epoch to decide whether to produce.
    epoch: u64,
    /// The epoch the last produce reflected. Starts one BEHIND epoch so the first
    /// frame produces exactly once (no never-drawn first frame): a fresh seam with
    /// a built tree has epoch == 1 and last_produced_epoch == 0, so has_changed is
    /// true on frame 1 and false on frame 2 absent a mutation.
    last_produced_epoch: u64,
    last_count: u32,
    last_recomputed: u32,
};

/// The drawable extent the reference tree is laid out into — the КТ-2 / e2e scene
/// is authored against this fixed size so the goldens are reproducible.
const REFERENCE_WIDTH: f32 = 1024;
const REFERENCE_HEIGHT: f32 = 640;

/// Allocates and initializes a seam on the C allocator, returning an opaque
/// handle. Returns null only if the allocation fails (the Swift side fatalErrors
/// on null). The tree starts empty with epoch 0; build_reference_tree (or, later,
/// the mutation bridge) populates it and bumps the epoch.
export fn facet_seam_create() callconv(.c) ?*anyopaque {
    const gpa = std.heap.c_allocator;
    const seam = gpa.create(Seam) catch return null;
    seam.* = .{
        .gpa = gpa,
        .tree = Tree.init(gpa),
        .producer = InstanceProducer.init(gpa),
        .root = null,
        .target = null,
        .epoch = 0,
        .last_produced_epoch = 0,
        .last_count = 0,
        .last_recomputed = 0,
    };
    return seam;
}

/// Frees the seam and everything it owns (tree arena + node map, producer buffer +
/// slot map). A null handle is a no-op so a double-destroy or a failed-create
/// teardown is safe.
export fn facet_seam_destroy(handle: ?*anyopaque) callconv(.c) void {
    const seam = cast(handle) orelse return;
    seam.producer.deinit();
    seam.tree.deinit();
    seam.gpa.destroy(seam);
}

/// Records the GPU-visible MTLBuffer span the seam writes instances into. Validates
/// the boundary (a null base or a zero capacity is rejected with a negative status
/// and the target is NOT recorded) and returns 0 on success. This does NOT make
/// give-instances infallible: the tree is built/mutated AFTER set-base-pointer, so
/// the count is unknown here — capacity is re-checked at give time and an overflow
/// there is a real reported status, prompting the Swift side to grow and re-hand.
export fn facet_seam_set_base_pointer(handle: ?*anyopaque, base: ?[*]Instance, capacity: u32) callconv(.c) c_int {
    const seam = cast(handle) orelse return -1;
    const base_pointer = base orelse return -1;
    if (capacity == 0) return -1;
    seam.target = .{ .base = base_pointer, .capacity = capacity };
    return 0;
}

/// Lays out the tree rooted at root_id, runs the dirty recompute for the frame
/// stats, then writes the instance array straight into the recorded target. On a
/// fitting write it returns the instance count (≥ 0); on an overflow it returns
/// the NEGATIVE encoding -(required + 1), so the Swift side decodes required =
/// -result - 1, grows the buffer 2×, re-hands the base, and retries. A valid count
/// is always ≥ 0 and every overflow value is ≤ -1; required is u32-bounded so the
/// widened -(required+1) never wraps in c_long. A missing target or unknown root is
/// a distinct -1.
export fn facet_seam_give_instances(handle: ?*anyopaque, root_id: u32, width: f32, height: f32) callconv(.c) c_long {
    const seam = cast(handle) orelse return -1;
    const target = seam.target orelse return -1;
    const root = seam.tree.lookup(root_id) orelse return -1;

    layout.layout(&seam.tree, root, .{ .x = 0, .y = 0, .width = width, .height = height }) catch return -1;
    const recomputed = dirty.recomputeDirty(&seam.tree, root) catch return -1;

    const outcome = seam.producer.buildInto(root, target) catch return -1;
    switch (outcome) {
        .written => |count| {
            seam.last_count = count;
            seam.last_recomputed = @intCast(recomputed);
            seam.last_produced_epoch = seam.epoch;
            return count;
        },
        .overflow => |required| return -(@as(c_long, required) + 1),
    }
}

/// Pure read: whether the tree changed since the last produce — the frame loop's
/// has-changed gate. The very first frame is a change (epoch 1 vs the initial
/// last_produced_epoch 0) so the tree is drawn once; a static frame after a
/// produce reads false.
export fn facet_seam_has_changed(handle: ?*anyopaque) callconv(.c) bool {
    const seam = cast(handle) orelse return false;
    return seam.epoch != seam.last_produced_epoch;
}

/// Builds the КТ-2 / e2e reference tree, registers its root, reserves the
/// producer's slot map for the node count (so buildInto never allocates mid-write),
/// bumps the epoch, and returns the root id. The scene is deliberately ASYMMETRIC
/// across the horizontal midline so a Y-flip is eye-visible and a golden cannot
/// self-bake one. On any allocation failure it leaves the tree untouched and
/// returns a sentinel root id of the max u32 (the Swift side fatalErrors on it).
export fn facet_seam_build_reference_tree(handle: ?*anyopaque) callconv(.c) u32 {
    const seam = cast(handle) orelse return std.math.maxInt(u32);
    const root = buildReferenceTree(&seam.tree) catch return std.math.maxInt(u32);
    seam.root = root;
    seam.producer.slots.ensureTotalCapacity(seam.tree.next_id) catch return std.math.maxInt(u32);
    seam.epoch += 1;
    return root.id;
}

/// Applies a paint-only mutation to the reference tree (recolors the top band) and
/// bumps the epoch so the next has-changed reports a change. Paint-only, so no node
/// is inserted and the reserved slot map still covers the tree.
export fn facet_seam_mutate_reference(handle: ?*anyopaque) callconv(.c) void {
    const seam = cast(handle) orelse return;
    const root = seam.root orelse return;
    mutateReference(root);
    seam.epoch += 1;
}

/// The node count the last give-instances recomputed — a Phase-13 frame-stat input
/// for the overlay. A static frame recomputes nothing, so this reads 0.
export fn facet_seam_last_recomputed(handle: ?*anyopaque) callconv(.c) u32 {
    const seam = cast(handle) orelse return 0;
    return seam.last_recomputed;
}

/// The instance count the last give-instances wrote — the draw count the renderer
/// binds. Exposed so the Swift side can re-bind a static frame's prior count
/// without re-producing.
export fn facet_seam_last_count(handle: ?*anyopaque) callconv(.c) u32 {
    const seam = cast(handle) orelse return 0;
    return seam.last_count;
}

fn cast(handle: ?*anyopaque) ?*Seam {
    return @ptrCast(@alignCast(handle orelse return null));
}

/// The single ASYMMETRIC reference scene both the golden writer and the e2e test
/// drive through THIS Zig code (never rebuilt in Swift), so they are byte-identical
/// by construction. A row container splits the 1024×640 frame into a TOP band and a
/// BOTTOM band that differ in count, color, and size, so any Y-flip is visible to
/// the eye and to the golden-independent geometric spot-assert. The two bands are
/// fixed-size siblings under a flex column root; each band is a fixed-size row of
/// colored tiles. Coordinates resolve to: top band center y≈160, bottom band center
/// y≈480 (see REFERENCE_* and the layout below).
fn buildReferenceTree(t: *Tree) std.mem.Allocator.Error!*Node {
    const root = try t.createNode(.view);
    root.direction = .column;
    root.sizing_mode = .fixed;
    root.main_size = REFERENCE_HEIGHT;
    root.cross_size = REFERENCE_WIDTH;
    root.cross_align = .stretch;
    // The root is the full-frame background tile painted behind the two bands (a
    // laid-out .view is visible and emits its own instance — slot 0, the forward
    // paint-order base the bands layer over).
    root.color_r = ROOT_COLOR.r;
    root.color_g = ROOT_COLOR.g;
    root.color_b = ROOT_COLOR.b;
    root.color_a = 1;

    // Top band: a single wide magenta bar occupying the top 320px row.
    const top = try t.createNode(.view);
    top.sizing_mode = .fixed;
    top.main_size = REFERENCE_HEIGHT / 2;
    top.cross_align = .stretch;
    top.color_r = TOP_COLOR.r;
    top.color_g = TOP_COLOR.g;
    top.color_b = TOP_COLOR.b;
    top.color_a = 1;
    top.corner_radius = 0;
    try t.appendChild(root, top);

    // Bottom band: a teal bar occupying the bottom 320px row — a DIFFERENT color
    // and corner radius than the top, so top != bottom under any flip.
    const bottom = try t.createNode(.view);
    bottom.sizing_mode = .fixed;
    bottom.main_size = REFERENCE_HEIGHT / 2;
    bottom.cross_align = .stretch;
    bottom.color_r = BOTTOM_COLOR.r;
    bottom.color_g = BOTTOM_COLOR.g;
    bottom.color_b = BOTTOM_COLOR.b;
    bottom.color_a = 1;
    bottom.corner_radius = 24;
    try t.appendChild(root, bottom);

    return root;
}

/// The mutation the e2e "next frame" test drives: recolor the top band. The bottom
/// band is untouched, so the after-golden differs from the before-golden ONLY in
/// the top band — the asymmetric scene makes the change localizable.
fn mutateReference(root: *Node) void {
    const top = root.children.items[0];
    Tree.updateNodeProps(top, .{
        .color_r = MUTATED_TOP_COLOR.r,
        .color_g = MUTATED_TOP_COLOR.g,
        .color_b = MUTATED_TOP_COLOR.b,
    });
}

const Rgb = struct { r: f32, g: f32, b: f32 };
const ROOT_COLOR = Rgb{ .r = 0.08, .g = 0.09, .b = 0.12 };
const TOP_COLOR = Rgb{ .r = 0.92, .g = 0.20, .b = 0.55 };
const BOTTOM_COLOR = Rgb{ .r = 0.10, .g = 0.78, .b = 0.74 };
const MUTATED_TOP_COLOR = Rgb{ .r = 0.30, .g = 0.55, .b = 0.90 };

const testing = std.testing;

test "the comptime layout table matches the Instance struct stride, alignment, count, and every offset" {
    // The same assertion the build runs, re-asserted as a test so `zig build test`
    // (not only the static-lib compile) fails on a drifted field. A moved field
    // breaks the comptime assert in assertInstanceLayout AND this test.
    try testing.expectEqual(@as(usize, EXPECTED_STRIDE), @sizeOf(Instance));
    try testing.expectEqual(@as(usize, EXPECTED_ALIGNMENT), @alignOf(Instance));
    try testing.expectEqual(@as(usize, 26), @typeInfo(Instance).@"struct".fields.len);
    try testing.expectEqual(expected_offsets.len, @typeInfo(Instance).@"struct".fields.len);
    inline for (expected_offsets) |entry| {
        try testing.expectEqual(@as(usize, entry.offset), @offsetOf(Instance, entry.name));
    }
}

/// Drives a seam handle through the C exports exactly as Swift would, freeing it on
/// scope exit. Centralizes the create/destroy so each test reads as the call
/// sequence under test.
fn createSeam() *anyopaque {
    return facet_seam_create() orelse unreachable;
}

test "give-instances writes the reference tree's instances into an external stack target" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    const root_id = facet_seam_build_reference_tree(handle);
    try testing.expect(root_id != std.math.maxInt(u32));

    var buffer: [16]Instance = undefined;
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_base_pointer(handle, &buffer, buffer.len));

    const count = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    // A full-frame background root plus two bands → three SDF instances, in forward
    // paint order (root behind, then top, then bottom).
    try testing.expectEqual(@as(c_long, 3), count);

    // Slot 0 is the full-frame background.
    const background = buffer[0];
    try testing.expectEqual(ROOT_COLOR.r, background.colorR);
    try testing.expectEqual(@as(f32, REFERENCE_WIDTH), background.width);
    try testing.expectEqual(@as(f32, REFERENCE_HEIGHT), background.height);

    // Slot 1 is the magenta top band at the top half, its center at y = HEIGHT/4
    // (the row's main axis is vertical via the column root), spanning the width.
    const top = buffer[1];
    try testing.expectEqual(TOP_COLOR.r, top.colorR);
    try testing.expectEqual(TOP_COLOR.g, top.colorG);
    try testing.expectEqual(TOP_COLOR.b, top.colorB);
    try testing.expectEqual(@as(f32, REFERENCE_WIDTH), top.width);
    try testing.expectEqual(@as(f32, REFERENCE_HEIGHT / 2), top.height);
    try testing.expectEqual(@as(f32, REFERENCE_WIDTH / 2), top.positionX);
    try testing.expectEqual(@as(f32, REFERENCE_HEIGHT / 4), top.positionY);
    try testing.expectEqual(@as(u32, 0), top.type);

    // Slot 2 is the bottom band — a DIFFERENT color, radius, and vertical center,
    // the asymmetry a Y-flip would expose.
    const bottom = buffer[2];
    try testing.expectEqual(BOTTOM_COLOR.r, bottom.colorR);
    try testing.expectEqual(@as(f32, 24), bottom.cornerRadius);
    try testing.expectEqual(@as(f32, REFERENCE_HEIGHT * 3 / 4), bottom.positionY);
    try testing.expect(top.positionY != bottom.positionY);
}

test "has-changed is true on the first frame, false after a static produce, true once after a mutation" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    const root_id = facet_seam_build_reference_tree(handle);
    var buffer: [16]Instance = undefined;
    _ = facet_seam_set_base_pointer(handle, &buffer, buffer.len);

    // First frame: epoch 1 vs last_produced_epoch 0 → a change, so the tree draws
    // once and is not a never-drawn first frame.
    try testing.expect(facet_seam_has_changed(handle));
    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    // Second frame, no mutation: static → no change.
    try testing.expect(!facet_seam_has_changed(handle));

    // A paint mutation bumps the epoch → a change, true once.
    facet_seam_mutate_reference(handle);
    try testing.expect(facet_seam_has_changed(handle));
    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    try testing.expect(!facet_seam_has_changed(handle));
}

test "set-base-pointer rejects a null base and a zero capacity at the boundary" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    var buffer: [4]Instance = undefined;
    try testing.expect(facet_seam_set_base_pointer(handle, null, buffer.len) < 0);
    try testing.expect(facet_seam_set_base_pointer(handle, &buffer, 0) < 0);
    // A valid base + capacity is accepted.
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_base_pointer(handle, &buffer, buffer.len));
}

test "give-instances overflows with the required-count encoding and writes nothing into an undersized target" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    const root_id = facet_seam_build_reference_tree(handle);

    // The reference tree emits 3 instances; hand a capacity-2 target.
    var buffer = [_]Instance{std.mem.zeroes(Instance)} ** 2;
    const sentinel = std.mem.zeroes(Instance);
    _ = facet_seam_set_base_pointer(handle, &buffer, buffer.len);

    const result = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    // -(required + 1) with required == 3 → -4.
    try testing.expectEqual(@as(c_long, -4), result);
    const required: u32 = @intCast(-result - 1);
    try testing.expectEqual(@as(u32, 3), required);
    // The undersized target is byte-untouched on overflow.
    for (buffer) |entry| {
        try testing.expect(std.mem.eql(u8, std.mem.asBytes(&entry), std.mem.asBytes(&sentinel)));
    }
}

test "a give-instances with no recorded target is a distinct negative status" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    const root_id = facet_seam_build_reference_tree(handle);
    // No set_base_pointer call → no target recorded.
    try testing.expectEqual(@as(c_long, -1), facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT));
}

test "a static frame recomputes zero nodes and last-recomputed reports it" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    const root_id = facet_seam_build_reference_tree(handle);
    var buffer: [16]Instance = undefined;
    _ = facet_seam_set_base_pointer(handle, &buffer, buffer.len);

    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    // A second produce with no layout-dirty mutation recomputes nothing.
    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    try testing.expectEqual(@as(u32, 0), facet_seam_last_recomputed(handle));
    try testing.expectEqual(@as(u32, 3), facet_seam_last_count(handle));
}
