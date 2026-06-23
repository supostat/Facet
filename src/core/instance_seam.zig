const std = @import("std");
const tree = @import("tree.zig");
const layout = @import("layout.zig");
const dirty = @import("dirty.zig");
const hit_test = @import("hit_test.zig");
const instances = @import("instances.zig");
const measure_seam = @import("measure_seam.zig");
const shape_seam = @import("shape_seam.zig");
const Tree = tree.Tree;
const Node = tree.Node;
const Instance = instances.Instance;
const InstanceProducer = instances.InstanceProducer;
const ExternalTarget = instances.ExternalTarget;
const MeasureFn = measure_seam.MeasureFn;
const MeasureContext = measure_seam.MeasureContext;
const ShapeFn = shape_seam.ShapeFn;
const ShapeContext = shape_seam.ShapeContext;
const PlacedGlyph = tree.PlacedGlyph;

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
    // Reference the measure-seam contract's layout assertion from THIS module's
    // root comptime block too: a drifted MeasureRequest/MeasureResult offset then
    // fails the static-LIBRARY compile (instance_seam is the lib root), not only
    // measure_seam's native test. Mirrors the instance-layout gate above (Ф13/Ф14).
    measure_seam.assertMeasureLayoutAtBuild();
    // The Phase-14b shape-seam contract's layout gate, referenced from the same
    // root comptime so a drifted ShapeRequest/PlacedGlyphExtern offset fails the
    // static-LIBRARY compile too (Ф14, the variable-length mirror of the measure
    // gate above).
    shape_seam.assertShapeLayoutAtBuild();
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
    /// The Ф14 UPWARD-seam callback slot: the Core Text measure fn Swift installs
    /// via facet_seam_set_measure_callback, read LIVE at measure time. Each text
    /// node's MeasureContext holds `&seam.measure_fn` (a pointer to THIS slot), so
    /// installing after the tree is built needs no tree-walk patch. `null` until
    /// installed; a measure with a null slot is a CHECKED `orelse unreachable`
    /// panic under .ReleaseSafe (the install-order invariant must hold).
    measure_fn: ?MeasureFn,
    /// The MeasureContext each text node's MeasureCallback points into. Owned by
    /// the seam (not the arena) and pinned at a stable address so `&seam.measure_fn`
    /// inside it stays valid for the seam's lifetime; a single fit-content label is
    /// the only text node in the measure scene, so one context suffices.
    measure_context: MeasureContext,
    /// The Phase-14b UPWARD shape-seam callback slot: the Core Text shape fn Swift
    /// installs via facet_seam_set_shape_callback, read LIVE at shape time. The
    /// shape pass's ShapeContext holds `&seam.shape_fn` (a pointer to THIS slot), so
    /// installing after the tree is built needs no tree-walk patch. `null` until
    /// installed; a shape with a null slot is a CHECKED `orelse unreachable` panic
    /// under .ReleaseSafe (the install-order invariant must hold).
    shape_fn: ?ShapeFn,
    /// The ShapeContext the shape pass hands the adapter, pinned at a stable address
    /// so `&seam.shape_fn` inside it stays valid for the seam's lifetime. font_size
    /// is overwritten per text node at build (a scene fixture, like measure_context).
    shape_context: ShapeContext,
    /// The seam-owned growable scratch the shape adapter writes glyphs into before
    /// the arena dupe — NOT the tree arena and NOT the producer's Instance MTLBuffer
    /// (it holds PlacedGlyphExtern, the seam's own transport). Unmanaged: the seam's
    /// gpa is passed per grow; deinit'd at destroy.
    shape_scratch: std.ArrayList(shape_seam.PlacedGlyphExtern),
    /// The count of real Zig→Swift shape crossings so far. A static scene shapes its
    /// text leaf exactly once (gated on shape_source), so this stays 1 across two
    /// produces (the anti-chatty-seam guarantee for the shape half, Р10/§4).
    shape_crossings: u32,
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
        .measure_fn = null,
        // The slot pointer is wired to THIS seam's stable measure_fn here, so the
        // measure scene's text node can point its MeasureContext at the seam field.
        // font_size is overwritten per text node at build (it is a scene fixture).
        .measure_context = .{ .measure_fn_slot = &seam.measure_fn, .font_size = 0 },
        .shape_fn = null,
        // The shape context's slot pointer is wired to THIS seam's stable shape_fn
        // here, mirroring measure_context; font_size is overwritten at build.
        .shape_context = .{ .shape_fn_slot = &seam.shape_fn, .font_size = 0 },
        .shape_scratch = .empty,
        .shape_crossings = 0,
    };
    return seam;
}

/// Frees the seam and everything it owns (tree arena + node map, producer buffer +
/// slot map). A null handle is a no-op so a double-destroy or a failed-create
/// teardown is safe.
export fn facet_seam_destroy(handle: ?*anyopaque) callconv(.c) void {
    const seam = cast(handle) orelse return;
    seam.shape_scratch.deinit(seam.gpa);
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

/// Installs the Ф14 measure callback (the Swift Core Text seam, or a Zig stub in
/// host-native tests) into the seam's live slot. Rejects a null fn pointer with a
/// non-zero status (the slot stays unchanged); on success stores it and returns 0.
/// The per-node MeasureContext already points at `&seam.measure_fn`, so the value
/// is read live at the next measure — no tree-walk patch. MUST be called BEFORE the
/// first give-instances that measures the scene (the install-order invariant).
export fn facet_seam_set_measure_callback(handle: ?*anyopaque, callback: ?MeasureFn) callconv(.c) c_int {
    const seam = cast(handle) orelse return -1;
    const measure_fn = callback orelse return -1;
    seam.measure_fn = measure_fn;
    return 0;
}

/// The count of real Zig→Swift measure crossings so far — the cache MISSES. A
/// repeated (string, width) is a cache HIT that bypasses the seam and does NOT
/// increment this (the anti-chatty-seam guarantee, Р10/§4), so the e2e asserts it
/// stays 1 across two produces of the static measure scene. Reads the single
/// authority (the Tree's MeasureCache invocation counter); 0 on a null handle.
export fn facet_seam_measure_crossings(handle: ?*anyopaque) callconv(.c) u32 {
    const seam = cast(handle) orelse return 0;
    return @intCast(seam.tree.measure_cache.invocation_count);
}

/// Installs the Phase-14b shape callback (the Swift Core Text seam, or a Zig stub in
/// host-native tests) into the seam's live slot. Rejects a null fn pointer with a
/// non-zero status (the slot stays unchanged); on success stores it and returns 0.
/// The shape pass's ShapeContext already points at `&seam.shape_fn`, so the value is
/// read live at the next shape — no tree-walk patch. MUST be called BEFORE the first
/// give-instances that shapes the scene (the install-order invariant).
export fn facet_seam_set_shape_callback(handle: ?*anyopaque, callback: ?ShapeFn) callconv(.c) c_int {
    const seam = cast(handle) orelse return -1;
    const shape_fn = callback orelse return -1;
    seam.shape_fn = shape_fn;
    return 0;
}

/// The count of real Zig→Swift shape crossings so far. A static scene shapes its
/// text leaf exactly once (the shape_source gate), so this stays 1 across two
/// produces — the anti-chatty-seam guarantee for the shape half (Р10/§4). 0 on a
/// null handle.
export fn facet_seam_shape_crossings(handle: ?*anyopaque) callconv(.c) u32 {
    const seam = cast(handle) orelse return 0;
    return seam.shape_crossings;
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

    // The Phase-14b shape pass: after place positioned every .text node, cross the
    // shape seam for each one not yet shaped and write the per-glyph geometry onto
    // node.placed_glyphs so the producer expands it into glyph instances. Runs
    // before buildInto so the count it reserves covers the placed glyphs.
    shapeTextNodes(seam, root) catch return -1;

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

/// Builds the Ф14 MEASURE scene — a fit-content container hugging a single .text
/// leaf whose size is resolved by the measure seam (NOT the Phase-13 band scene).
/// Registers the root, reserves the producer slot map, bumps the epoch, and returns
/// the root id (max u32 sentinel on allocation failure). SEPARATE from
/// facet_seam_build_reference_tree so the Phase-13 scene + its goldens stay
/// byte-untouched. The text node's MeasureContext points at the seam's measure_fn
/// slot, so a callback installed afterward is read live.
export fn facet_seam_build_measure_tree(handle: ?*anyopaque) callconv(.c) u32 {
    const seam = cast(handle) orelse return std.math.maxInt(u32);
    const root = buildMeasureReferenceTree(seam) catch return std.math.maxInt(u32);
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

/// The seam-measured main-axis extent of a node, read back for the Ф14 fit-content
/// GEOMETRY check: the laid-out rect width of the node id (the measure scene's
/// label container is a ROW, so its main axis is horizontal == the rect width).
/// After a produce, this hugs the real Core-Text-measured text width. Returns 0 for
/// a null handle or unknown id (the boundary no-op).
export fn facet_seam_node_laid_out_main(handle: ?*anyopaque, node_id: u32) callconv(.c) f32 {
    const seam = cast(handle) orelse return 0;
    const node = seam.tree.lookup(node_id) orelse return 0;
    return node.layout.w;
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

/// The Phase-14b shape pass: a post-order walk that, for each .text node not yet
/// shaped, crosses the seam to shape its laid-out string, dupes the returned glyphs
/// into the tree arena onto node.placed_glyphs (the frame-stable copy — the seam
/// scratch is borrowed and reused per call), and marks the provenance. Gated on
/// shape_source == .unshaped so a static frame re-shapes nothing (the anti-chatty
/// shape seam). Post-order so the walk reads each node's final placed rect (place
/// already ran top-down, but post-order matches the measure-pass discipline). The
/// arena allocator is re-fetched from the stable *Tree per dupe (never stored).
fn shapeTextNodes(seam: *Seam, node: *Node) std.mem.Allocator.Error!void {
    for (node.children.items) |child| try shapeTextNodes(seam, child);
    if (!needsShaping(seam, node)) return;

    seam.shape_context.font_size = node.font_size;
    const glyphs = try shape_seam.shapeThroughSeam(&seam.shape_context, &seam.shape_scratch, seam.gpa, node);
    node.placed_glyphs = try seam.tree.arena.allocator().dupe(PlacedGlyph, glyphs);
    node.shape_source = .shape_cross;
    seam.shape_crossings += 1;
}

/// Whether a node crosses the shape seam this frame: a .text node the shape pass has
/// not yet crossed for (shape_source == .unshaped) WHEN a shape callback is
/// installed. The provenance gate is the anti-chatty signal (consistent with the
/// measure cache's invocation discipline, ready for a future layout-dirty re-shape
/// phase); the installed-callback gate keeps the measure-only path (Phase-14 e2e: a
/// measure scene produced with no shape callback) from crossing into the checked
/// `orelse unreachable` — a text leaf simply stays unshaped and emits no glyphs,
/// exactly the pre-14b state. The shape e2e/КТ-2/app install the callback first.
fn needsShaping(seam: *const Seam, node: *const Node) bool {
    return node.kind == .text and node.shape_source == .unshaped and seam.shape_fn != null;
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

/// The Ф14 measure scene fixtures: the caption string the seam measures and the
/// point size the node hands the seam (deviation a — fixed family Swift-side, the
/// node names the size). The Swift ReferenceZigTree mirrors these so the
/// seam-fidelity + fit-content geometry asserts measure the SAME bytes + size.
const MEASURE_STRING = "Facet";
const MEASURE_FONT_SIZE: f32 = 32;
const MEASURE_LABEL_COLOR = Rgb{ .r = 0.90, .g = 0.92, .b = 0.96 };
/// The Phase-14b glyph color: a dark ink that tints the R8 coverage so the shaped
/// "Facet" reads legibly against the light label box. A .text node's color tints its
/// glyph instances (instances.glyphInstance), so without it the glyphs default to a
/// fully transparent color_a == 0 and draw nothing.
const MEASURE_TEXT_COLOR = Rgb{ .r = 0.10, .g = 0.11, .b = 0.16 };

/// Builds the SEPARATE measure scene: a fixed full-frame root with a single
/// fit-content label container that hugs a .text leaf. The leaf carries its string,
/// its font size, and a MeasureCallback whose adapter is measureThroughSeam and
/// whose context is the seam-owned MeasureContext (pointing at the live measure_fn
/// slot). After the measure pass the label container's `preferred.main` == the
/// seam-measured text main; because the container is a fit_content CHILD (not the
/// root), the place pass sizes its laid-out rect to that preference — so
/// `label_container.layout.w` is the SDF box hugging the measured text width (the
/// legible glyph render is deferred to Phase 14b). NOT the Phase-13 band scene.
fn buildMeasureReferenceTree(seam: *Seam) std.mem.Allocator.Error!*Node {
    const t = &seam.tree;
    // The fixed full-frame root: a ROW that places its single fit-content child at
    // the top-left. Row so the child's main axis (horizontal, the measured text
    // width) maps to the child's laid-out rect WIDTH — the hugging box the geometry
    // check reads. The root rect is the whole drawable; the label container hugs.
    const root = try t.createNode(.view);
    root.direction = .row;
    root.sizing_mode = .fixed;
    root.main_size = REFERENCE_WIDTH;
    root.cross_size = REFERENCE_HEIGHT;
    root.cross_align = .start;
    root.color_r = ROOT_COLOR.r;
    root.color_g = ROOT_COLOR.g;
    root.color_b = ROOT_COLOR.b;
    root.color_a = 1;

    // The fit-content label container: a row hugging the text leaf. As a fit_content
    // CHILD its laid-out rect is sized to its measured preference (the place pass
    // reads child.preferred for fit_content), so its rect hugs the measured text.
    const label_container = try t.createNode(.view);
    label_container.direction = .row;
    label_container.sizing_mode = .fit_content;
    label_container.cross_align = .start;
    label_container.color_r = MEASURE_LABEL_COLOR.r;
    label_container.color_g = MEASURE_LABEL_COLOR.g;
    label_container.color_b = MEASURE_LABEL_COLOR.b;
    label_container.color_a = 1;
    try t.appendChild(root, label_container);

    const label = try t.createNode(.text);
    label.sizing_mode = .fit_content;
    label.text = MEASURE_STRING;
    label.font_size = MEASURE_FONT_SIZE;
    // The glyph ink color: a .text node's color tints its glyph instances, so the
    // shaped "Facet" reads as dark ink on the light label box (an unset color_a == 0
    // would draw nothing).
    label.color_r = MEASURE_TEXT_COLOR.r;
    label.color_g = MEASURE_TEXT_COLOR.g;
    label.color_b = MEASURE_TEXT_COLOR.b;
    label.color_a = 1;
    seam.measure_context.font_size = MEASURE_FONT_SIZE;
    // The shape pass reads the node's own font_size per cross (shapeTextNodes), so
    // this seam-level seed mirrors measure_context for parity; the per-node write is
    // the authority.
    seam.shape_context.font_size = MEASURE_FONT_SIZE;
    label.measure_callback = .{
        .context = &seam.measure_context,
        .measure = measure_seam.measureThroughSeam,
    };
    try t.appendChild(label_container, label);

    return root;
}

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

/// A Zig stub MeasureFn standing in for the Swift Core Text seam in host-native
/// measure-scene tests (deviation c — real Core Text is host-unavailable). It
/// returns a width proportional to length × font size and a height of the font
/// size, deterministic so the scene asserts are exact.
const STUB_MAIN_PER_UNIT: f32 = 0.6;

fn stubMeasureCallback(request: *const measure_seam.MeasureRequest, result: *measure_seam.MeasureResult) callconv(.c) void {
    result.* = .{
        .main = @as(f32, @floatFromInt(request.length)) * request.font_size * STUB_MAIN_PER_UNIT,
        .cross = request.font_size,
    };
}

fn expectedStubMain() f32 {
    return @as(f32, @floatFromInt(MEASURE_STRING.len)) * MEASURE_FONT_SIZE * STUB_MAIN_PER_UNIT;
}

test "the measure scene sizes the text leaf and the hugging container through the installed seam callback" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    // Install the stub BEFORE the first produce (the install-order invariant: a
    // measure with a null slot is a checked panic).
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_measure_callback(handle, stubMeasureCallback));

    const root_id = facet_seam_build_measure_tree(handle);
    try testing.expect(root_id != std.math.maxInt(u32));

    var buffer: [16]Instance = undefined;
    _ = facet_seam_set_base_pointer(handle, &buffer, buffer.len);
    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);

    // The text leaf is id 2 (root 0, label container 1, text leaf 2); it measured
    // through the seam to the stub's size and recorded the crossing provenance.
    const seam = cast(handle).?;
    const label = seam.tree.lookup(2).?;
    try testing.expectEqual(MEASURE_STRING, label.text.?);
    try testing.expectEqual(expectedStubMain(), label.preferred.main);
    try testing.expectEqual(MEASURE_FONT_SIZE, label.preferred.cross);
    try testing.expectEqual(tree.MeasureSource.seam_cross, label.measure_source);

    // The fit-content label container (id 1) is sized to hug the measured text: its
    // laid-out main extent (a row → the rect width) equals the seam-measured main.
    try testing.expectEqual(expectedStubMain(), facet_seam_node_laid_out_main(handle, root_id + 1));
}

test "the measure crossing counter stays one after two produces of the static measure scene" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    try testing.expectEqual(@as(c_int, 0), facet_seam_set_measure_callback(handle, stubMeasureCallback));
    const root_id = facet_seam_build_measure_tree(handle);
    var buffer: [16]Instance = undefined;
    _ = facet_seam_set_base_pointer(handle, &buffer, buffer.len);

    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    // The second produce re-measures the same (string, width): an all-HIT, so the
    // seam is bypassed and the crossing counter does NOT increment past one.
    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    try testing.expectEqual(@as(u32, 1), facet_seam_measure_crossings(handle));
}

test "set-measure-callback rejects a null fn and is a no-op on a null handle, and crossings reads zero before any measure" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    // A null fn pointer is rejected (the slot stays null); a valid one is accepted.
    try testing.expect(facet_seam_set_measure_callback(handle, null) < 0);
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_measure_callback(handle, stubMeasureCallback));

    // A null handle is a distinct boundary no-op on every measure export.
    try testing.expect(facet_seam_set_measure_callback(null, stubMeasureCallback) < 0);
    try testing.expectEqual(@as(u32, 0), facet_seam_measure_crossings(null));
    try testing.expectEqual(@as(f32, 0), facet_seam_node_laid_out_main(null, 0));

    // No produce yet → no crossing.
    try testing.expectEqual(@as(u32, 0), facet_seam_measure_crossings(handle));
}

/// A Zig stub ShapeFn standing in for the Swift Core Text shape seam in host-native
/// measure-scene tests (real Core Text is host-unavailable). It emits one glyph per
/// byte at a strictly-increasing center_x anchored at the request origin, so the
/// scene asserts the glyph instances are produced and ordered. On a too-small
/// capacity it writes nothing and returns the overflow encoding.
const STUB_GLYPH_ADVANCE: f32 = 18;

fn stubShapeCallback(request: *const shape_seam.ShapeRequest, destination: [*]shape_seam.PlacedGlyphExtern, capacity: c_long) callconv(.c) c_long {
    const required: usize = request.length;
    if (@as(c_long, @intCast(required)) > capacity) {
        return -(@as(c_long, @intCast(required)) + 1);
    }
    var index: usize = 0;
    while (index < required) : (index += 1) {
        const step: f32 = @floatFromInt(index);
        destination[index] = .{
            .center_x = request.origin_x + step * STUB_GLYPH_ADVANCE,
            .center_y = request.origin_y + request.font_size,
            .width = request.font_size,
            .height = request.font_size,
            .atlas_min_u = 0,
            .atlas_min_v = 0,
            .atlas_max_u = 1,
            .atlas_max_v = 1,
        };
    }
    return @intCast(required);
}

test "the measure scene shapes its text leaf through the installed shape seam and emits one glyph instance per byte" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    // Both upward seams installed BEFORE the first produce (the install-order
    // invariant: a measure/shape with a null slot is a checked panic).
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_measure_callback(handle, stubMeasureCallback));
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_shape_callback(handle, stubShapeCallback));

    const root_id = facet_seam_build_measure_tree(handle);
    var buffer: [16]Instance = undefined;
    _ = facet_seam_set_base_pointer(handle, &buffer, buffer.len);
    const count = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);

    // The text leaf (id 2) gained one placed glyph per byte and recorded the shape
    // crossing provenance.
    const seam = cast(handle).?;
    const label = seam.tree.lookup(2).?;
    try testing.expectEqual(@as(usize, MEASURE_STRING.len), (label.placed_glyphs orelse &.{}).len);
    try testing.expectEqual(tree.ShapeSource.shape_cross, label.shape_source);

    // The produced instances are the background root, the label container, and one
    // glyph instance per byte; the glyph instances carry the glyph type and follow
    // the SDF rects in forward paint order.
    try testing.expectEqual(@as(c_long, 2 + @as(c_long, MEASURE_STRING.len)), count);
    const glyph_type = @intFromEnum(instances.InstanceType.glyph);
    var index: usize = 2;
    while (index < @as(usize, @intCast(count))) : (index += 1) {
        try testing.expectEqual(@as(u32, glyph_type), buffer[index].type);
    }
    // The glyph centers strictly increase along the line (no fixed pen / overlap).
    try testing.expect(buffer[3].positionX > buffer[2].positionX);
}

test "the shape crossing counter stays one after two produces of the static measure scene" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    try testing.expectEqual(@as(c_int, 0), facet_seam_set_measure_callback(handle, stubMeasureCallback));
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_shape_callback(handle, stubShapeCallback));
    const root_id = facet_seam_build_measure_tree(handle);
    var buffer: [16]Instance = undefined;
    _ = facet_seam_set_base_pointer(handle, &buffer, buffer.len);

    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    // The second produce finds the text leaf already shape_cross, so it does NOT
    // re-cross — the anti-chatty shape seam.
    _ = facet_seam_give_instances(handle, root_id, REFERENCE_WIDTH, REFERENCE_HEIGHT);
    try testing.expectEqual(@as(u32, 1), facet_seam_shape_crossings(handle));
}

test "set-shape-callback rejects a null fn and a null handle, and crossings reads zero before any produce" {
    const handle = createSeam();
    defer facet_seam_destroy(handle);

    // A null fn pointer is rejected (the slot stays null); a valid one is accepted.
    try testing.expect(facet_seam_set_shape_callback(handle, null) < 0);
    try testing.expectEqual(@as(c_int, 0), facet_seam_set_shape_callback(handle, stubShapeCallback));

    // A null handle is a distinct boundary no-op on every shape export.
    try testing.expect(facet_seam_set_shape_callback(null, stubShapeCallback) < 0);
    try testing.expectEqual(@as(u32, 0), facet_seam_shape_crossings(null));

    // No produce yet → no crossing.
    try testing.expectEqual(@as(u32, 0), facet_seam_shape_crossings(handle));
}
