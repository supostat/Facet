const std = @import("std");
const tree = @import("tree.zig");
const PlacedGlyph = tree.PlacedGlyph;

// shape_seam.zig carries the SECOND upward half of the lower C-ABI seam (Ф14,
// Р10): after the place pass positions a fit-content .text leaf, the shape pass
// asks the Swift platform layer to shape its string with real Core Text and reads
// the per-glyph geometry back. It is the VARIABLE-LENGTH mirror of measure_seam.zig
// (which returns a fixed {main, cross}); the shape result is an array of glyphs
// whose count Zig does not know until the callback returns. Strict inward rule:
// this module imports ONLY tree.zig — never instance_seam.zig. The decoupling is
// the ShapeContext holding a `*const ?ShapeFn` (a pointer to the seam-owned
// callback slot), NOT a *Seam and NOT a copied fn, so the live callback value is
// read at shape time (install-after-build is correct with no tree-walk patch) and
// there is no circular import.

/// The request the seam packs and hands across the C boundary on a shape: the text
/// bytes (pointer + length, a zero-copy borrow valid only WITHIN the call — the
/// Swift side decodes a String and never retains the pointer), the point size the
/// node names, the ABSOLUTE laid-out top-left origin of the text node (PlacedGlyph
/// centers are absolute drawable-pixel positions, so shaping must anchor at the
/// node's placed box), and the proposed main-axis wrap width. The field names are
/// snake here but mirror the C `FacetShapeRequest` 1:1 by offset; the FROZEN
/// offsets are pinned by assertShapeLayout below. `proposed_wrap_width` is carried
/// but NOT consulted for geometry yet (single-line, no wrap shaper — exactly as
/// measure_seam's `proposed_main`).
pub const ShapeRequest = extern struct {
    bytes: [*]const u8,
    length: usize,
    font_size: f32,
    origin_x: f32,
    origin_y: f32,
    proposed_wrap_width: f32,
};

/// One shaped glyph the seam reads back: the C mirror of tree.PlacedGlyph (the
/// source of truth) — the absolute cell center, the full cell extent, and the
/// glyph's normalized atlas sub-rectangle. 8 f32 / 32 bytes; mirrors the C
/// `FacetPlacedGlyph` 1:1 by offset (frozen below). Field names IDENTICAL to
/// tree.PlacedGlyph so the cross-struct pin reads each offset by the same name.
pub const PlacedGlyphExtern = extern struct {
    center_x: f32,
    center_y: f32,
    width: f32,
    height: f32,
    atlas_min_u: f32,
    atlas_min_v: f32,
    atlas_max_u: f32,
    atlas_max_v: f32,
};

/// The C-ABI callback Swift installs: given a request, write up to `capacity`
/// glyphs into the destination buffer and return the count written (≥ 0), or the
/// NEGATIVE encoding -(required + 1) when `capacity` is too small so Zig grows the
/// seam-owned scratch and re-calls (mirrors give_instances' c_long count-or-
/// -(required+1) encoding). Lowercase `callconv(.c)` (the 0.15.2 spelling). The
/// Optional in the seam slot is the pre-install state; the value is non-optional
/// here because the seam only ever stores an installed callback.
pub const ShapeFn = *const fn (*const ShapeRequest, [*]PlacedGlyphExtern, c_long) callconv(.c) c_long;

/// The FROZEN byte offset of every field of the two extern structs — the Ф14
/// source-of-truth layout the C `FacetShapeRequest`/`FacetPlacedGlyph` mirror
/// (verified arm64-apple-macosx26.0). A reorder/insert moves one of these and fails
/// the comptime assertion AND the co-located test, so the build and `zig build
/// test` both break on drift (mirrors measure_seam's ExpectedOffset tables).
const ExpectedOffset = struct {
    name: []const u8,
    offset: comptime_int,
};

const request_offsets = [_]ExpectedOffset{
    .{ .name = "bytes", .offset = 0 },
    .{ .name = "length", .offset = 8 },
    .{ .name = "font_size", .offset = 16 },
    .{ .name = "origin_x", .offset = 20 },
    .{ .name = "origin_y", .offset = 24 },
    .{ .name = "proposed_wrap_width", .offset = 28 },
};

const glyph_offsets = [_]ExpectedOffset{
    .{ .name = "center_x", .offset = 0 },
    .{ .name = "center_y", .offset = 4 },
    .{ .name = "width", .offset = 8 },
    .{ .name = "height", .offset = 12 },
    .{ .name = "atlas_min_u", .offset = 16 },
    .{ .name = "atlas_min_v", .offset = 20 },
    .{ .name = "atlas_max_u", .offset = 24 },
    .{ .name = "atlas_max_v", .offset = 28 },
};

const REQUEST_SIZE = 32;
const REQUEST_ALIGNMENT = 8;
const GLYPH_SIZE = 32;
const GLYPH_ALIGNMENT = 4;

/// Compile-time check of both contract structs against the frozen tables: size,
/// alignment, field count, and every field offset, PLUS the cross-struct pin that
/// PlacedGlyphExtern is byte-identical to tree.PlacedGlyph (so the @ptrCast return
/// path in shapeThroughSeam is sound) and every shared field sits at the same
/// offset. Referenced from a top-level `comptime {}` block AND re-asserted in a
/// co-located test, so a drifted field fails the native-test compile (and,
/// transitively, the static-lib compile when instance_seam.zig imports this module)
/// before any runtime. A PLAIN `for` inside `comptime {}` — `inline for` inside a
/// comptime scope is a hard compile error in Zig 0.15.2 (redundant inline keyword).
fn assertShapeLayout() void {
    comptime {
        std.debug.assert(@sizeOf(ShapeRequest) == REQUEST_SIZE);
        std.debug.assert(@alignOf(ShapeRequest) == REQUEST_ALIGNMENT);
        std.debug.assert(@typeInfo(ShapeRequest).@"struct".fields.len == request_offsets.len);
        for (request_offsets) |entry| {
            std.debug.assert(@offsetOf(ShapeRequest, entry.name) == entry.offset);
        }
        std.debug.assert(@sizeOf(PlacedGlyphExtern) == GLYPH_SIZE);
        std.debug.assert(@alignOf(PlacedGlyphExtern) == GLYPH_ALIGNMENT);
        std.debug.assert(@typeInfo(PlacedGlyphExtern).@"struct".fields.len == glyph_offsets.len);
        for (glyph_offsets) |entry| {
            std.debug.assert(@offsetOf(PlacedGlyphExtern, entry.name) == entry.offset);
        }
        // Cross-struct pin: the extern transport and the tree source of truth share
        // a size and every field offset, so the @ptrCast prefix in shapeThroughSeam
        // reinterprets the scratch as []const tree.PlacedGlyph correctly.
        std.debug.assert(@sizeOf(PlacedGlyphExtern) == @sizeOf(PlacedGlyph));
        std.debug.assert(@typeInfo(PlacedGlyph).@"struct".fields.len == glyph_offsets.len);
        for (glyph_offsets) |entry| {
            std.debug.assert(@offsetOf(PlacedGlyph, entry.name) == entry.offset);
        }
    }
}

comptime {
    assertShapeLayout();
}

/// A `pub` comptime entry so the outer instance_seam.zig root module can reference
/// the same frozen-layout gate from ITS top-level `comptime {}` block — then a
/// drifted offset fails the static-LIBRARY compile, not only this module's native
/// test. Mirrors measure_seam.assertMeasureLayoutAtBuild.
pub fn assertShapeLayoutAtBuild() void {
    comptime assertShapeLayout();
}

/// The decoupled carrier the shape pass hands the adapter. It holds a POINTER to the
/// seam-owned `?ShapeFn` slot (so the callback value is read LIVE at shape time —
/// set AFTER tree build with no tree-walk patch) plus the node's font size (the
/// Node field, captured at build). It does NOT hold a *Seam, so this module never
/// imports instance_seam.zig.
pub const ShapeContext = struct {
    shape_fn_slot: *const ?ShapeFn,
    font_size: f32,
};

/// The shape-pass adapter the seam drives for each placed .text node: packs a
/// ShapeRequest from the context's font size, the node's text bytes, and the node's
/// laid-out top-left box, reads the LIVE callback from the slot (a CHECKED `orelse
/// unreachable` panic under .ReleaseSafe — guaranteed installed by the install-order
/// invariant), and writes the returned glyphs into the seam-owned `scratch`,
/// growing + re-calling on the overflow encoding. Returns the written prefix as
/// []const tree.PlacedGlyph (the @ptrCast is sound — the layout is comptime-pinned);
/// the caller dupes it into the arena, which is the real frame-stable copy. The
/// scratch is borrowed: a later shape reuses + may overwrite it. The text slice is
/// borrowed zero-copy for the duration of the call only.
pub fn shapeThroughSeam(
    context: *const ShapeContext,
    scratch: *std.ArrayList(PlacedGlyphExtern),
    gpa: std.mem.Allocator,
    node: *const tree.Node,
) std.mem.Allocator.Error![]const PlacedGlyph {
    const callback = context.shape_fn_slot.* orelse unreachable;
    const text = node.text orelse unreachable;
    var request = ShapeRequest{
        .bytes = text.ptr,
        .length = text.len,
        .font_size = context.font_size,
        .origin_x = node.layout.x,
        .origin_y = node.layout.y,
        .proposed_wrap_width = node.layout.w,
    };

    // Hand the callback at least one slot of capacity so its destination pointer is
    // always valid (an unmanaged ArrayList's items.ptr is meaningful once capacity
    // > 0). On the overflow encoding grow to the required count and re-call; the
    // grown buffer is guaranteed to fit, so the second result is non-negative.
    try scratch.ensureTotalCapacity(gpa, @max(scratch.capacity, 1));
    var count = callback(&request, scratch.items.ptr, @intCast(scratch.capacity));
    if (count < 0) {
        const required: usize = @intCast(-count - 1);
        try scratch.ensureTotalCapacity(gpa, required);
        count = callback(&request, scratch.items.ptr, @intCast(scratch.capacity));
        std.debug.assert(count >= 0);
    }

    // ensureTotalCapacity does not move items.len off zero, so set the written
    // length explicitly before slicing.
    const written: usize = @intCast(count);
    scratch.items.len = written;
    return @ptrCast(scratch.items[0..written]);
}

const testing = std.testing;

test "the comptime layout tables match the request/glyph struct size, alignment, count, and every offset" {
    // The same assertion the build runs, re-asserted so `zig build test` (not only
    // the static-lib compile) fails on a drifted field.
    try testing.expectEqual(@as(usize, REQUEST_SIZE), @sizeOf(ShapeRequest));
    try testing.expectEqual(@as(usize, REQUEST_ALIGNMENT), @alignOf(ShapeRequest));
    try testing.expectEqual(request_offsets.len, @typeInfo(ShapeRequest).@"struct".fields.len);
    inline for (request_offsets) |entry| {
        try testing.expectEqual(@as(usize, entry.offset), @offsetOf(ShapeRequest, entry.name));
    }

    try testing.expectEqual(@as(usize, GLYPH_SIZE), @sizeOf(PlacedGlyphExtern));
    try testing.expectEqual(@as(usize, GLYPH_ALIGNMENT), @alignOf(PlacedGlyphExtern));
    try testing.expectEqual(glyph_offsets.len, @typeInfo(PlacedGlyphExtern).@"struct".fields.len);
    inline for (glyph_offsets) |entry| {
        try testing.expectEqual(@as(usize, entry.offset), @offsetOf(PlacedGlyphExtern, entry.name));
    }

    // The cross-struct pin: the extern transport is byte-identical to the tree
    // source of truth, so the @ptrCast return path is sound.
    try testing.expectEqual(@sizeOf(PlacedGlyph), @sizeOf(PlacedGlyphExtern));
    try testing.expectEqual(glyph_offsets.len, @typeInfo(PlacedGlyph).@"struct".fields.len);
    inline for (glyph_offsets) |entry| {
        try testing.expectEqual(@offsetOf(PlacedGlyphExtern, entry.name), @offsetOf(PlacedGlyph, entry.name));
    }
}

/// A Zig stub ShapeFn standing in for the Swift Core Text callback in host-native
/// tests (deviation c): it emits one glyph per byte of the request, each centered at
/// the request origin plus a per-index step so a test can prove the adapter packed
/// the request faithfully and unpacked the variable-count result. On a too-small
/// capacity it writes NOTHING and returns the overflow encoding -(required + 1).
fn stubShape(request: *const ShapeRequest, destination: [*]PlacedGlyphExtern, capacity: c_long) callconv(.c) c_long {
    const required: usize = request.length;
    if (@as(c_long, @intCast(required)) > capacity) {
        return -(@as(c_long, @intCast(required)) + 1);
    }
    var index: usize = 0;
    while (index < required) : (index += 1) {
        const step: f32 = @floatFromInt(index);
        destination[index] = .{
            .center_x = request.origin_x + step,
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

fn stubNode(text: []const u8) tree.Node {
    return .{
        .id = 0,
        .kind = .text,
        .text = text,
        .layout = .{ .x = 100, .y = 50, .w = 200, .h = 32 },
    };
}

test "the adapter packs the request from the node and unpacks the variable-count glyph result" {
    var slot: ?ShapeFn = stubShape;
    const context = ShapeContext{ .shape_fn_slot = &slot, .font_size = 32 };
    var scratch: std.ArrayList(PlacedGlyphExtern) = .empty;
    defer scratch.deinit(testing.allocator);

    const node = stubNode("Facet");
    const glyphs = try shapeThroughSeam(&context, &scratch, testing.allocator, &node);

    // One glyph per byte, anchored at the laid-out origin with the per-index step.
    try testing.expectEqual(@as(usize, 5), glyphs.len);
    try testing.expectEqual(@as(f32, 100), glyphs[0].center_x);
    try testing.expectEqual(@as(f32, 104), glyphs[4].center_x);
    try testing.expectEqual(@as(f32, 50 + 32), glyphs[0].center_y);
    try testing.expectEqual(@as(f32, 32), glyphs[0].width);
}

test "the adapter reads the callback LIVE from the slot, so an install after context construction is seen" {
    var slot: ?ShapeFn = null;
    const context = ShapeContext{ .shape_fn_slot = &slot, .font_size = 16 };
    var scratch: std.ArrayList(PlacedGlyphExtern) = .empty;
    defer scratch.deinit(testing.allocator);

    // The slot is installed AFTER the context was built (the Ф14 install-order).
    slot = stubShape;
    const node = stubNode("ab");
    const glyphs = try shapeThroughSeam(&context, &scratch, testing.allocator, &node);

    try testing.expectEqual(@as(usize, 2), glyphs.len);
}

test "the adapter grows the scratch and retries on the overflow encoding, writing nothing past the first capacity" {
    var slot: ?ShapeFn = stubShape;
    const context = ShapeContext{ .shape_fn_slot = &slot, .font_size = 10 };
    var scratch: std.ArrayList(PlacedGlyphExtern) = .empty;
    defer scratch.deinit(testing.allocator);

    // A 7-byte string needs 7 glyphs; the first call hands capacity 1 (the @max
    // floor), so the stub returns -(7+1) and the adapter grows to 7 and re-calls.
    const node = stubNode("Glyphic");

    // The under-capacity call writes NOTHING past the handed capacity and returns the
    // overflow encoding -(required + 1) — the precondition the adapter grows on.
    var probe = ShapeRequest{
        .bytes = node.text.?.ptr,
        .length = node.text.?.len,
        .font_size = context.font_size,
        .origin_x = node.layout.x,
        .origin_y = node.layout.y,
        .proposed_wrap_width = node.layout.w,
    };
    var one_slot: [1]PlacedGlyphExtern = undefined;
    try testing.expectEqual(@as(c_long, -(7 + 1)), stubShape(&probe, &one_slot, 1));

    const glyphs = try shapeThroughSeam(&context, &scratch, testing.allocator, &node);

    try testing.expectEqual(@as(usize, 7), glyphs.len);
    try testing.expect(scratch.capacity >= 7);
}

test "an empty string shapes to zero glyphs without crossing into a negative count" {
    var slot: ?ShapeFn = stubShape;
    const context = ShapeContext{ .shape_fn_slot = &slot, .font_size = 12 };
    var scratch: std.ArrayList(PlacedGlyphExtern) = .empty;
    defer scratch.deinit(testing.allocator);

    const node = stubNode("");
    const glyphs = try shapeThroughSeam(&context, &scratch, testing.allocator, &node);

    try testing.expectEqual(@as(usize, 0), glyphs.len);
}
