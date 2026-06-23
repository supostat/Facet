const std = @import("std");
const tree = @import("tree.zig");
const MeasuredSize = tree.MeasuredSize;

// measure_seam.zig carries the UPWARD half of the lower C-ABI seam (Ф14, Р10):
// the measure pass asks the Swift platform layer to measure a text run with real
// Core Text and reads metrics back. It is the mirror of instance_seam.zig's
// DOWNWARD instance write. Strict inward rule (deviation d): this module imports
// ONLY tree.zig — never instance_seam.zig. The decoupling is the MeasureContext
// holding a `*?MeasureFn` (a pointer to the seam-owned callback slot), NOT a
// *Seam and NOT a copied fn, so the live callback value is read at measure time
// (install-after-build is correct with no tree-walk patch) and there is no
// circular import even though Zig would tolerate one.

/// The request the seam packs and hands across the C boundary on a measure: the
/// text bytes (pointer + length, a zero-copy borrow valid only WITHIN the call —
/// the Swift side decodes a String and never retains the pointer), the point size
/// the node names, and the proposed main-axis wrap width. The field names are
/// camelCase-free snake here but mirror the C `FacetMeasureRequest` 1:1 by offset;
/// the FROZEN offsets are pinned by assertMeasureLayout below. `proposed_main` is
/// carried but NOT consulted for geometry yet (single-line CTLineGetTypographicBounds;
/// no wrap shaper — a future phase).
pub const MeasureRequest = extern struct {
    bytes: [*]const u8,
    length: usize,
    font_size: f32,
    proposed_main: f32,
};

/// The metrics the seam reads back: the measured main-axis extent (the line's
/// typographic width) and the cross-axis extent (ascent + descent + leading).
/// Mirrors the C `FacetMeasureResult` 1:1 by offset (frozen below).
pub const MeasureResult = extern struct {
    main: f32,
    cross: f32,
};

/// The C-ABI callback Swift installs: given a request, fill a result. Lowercase
/// `callconv(.c)` (the 0.15.2 spelling). The Optional in the seam slot is the
/// pre-install state; the value is non-optional here because the seam only ever
/// stores an installed callback.
pub const MeasureFn = *const fn (*const MeasureRequest, *MeasureResult) callconv(.c) void;

/// The FROZEN byte offset of every field of the two extern structs — the Ф14
/// source-of-truth layout the C `FacetMeasureRequest`/`FacetMeasureResult` mirror
/// (verified arm64-apple-macosx26.0). A reorder/insert moves one of these and
/// fails the comptime assertion AND the co-located test, so the build and
/// `zig build test` both break on drift (mirrors instance_seam's expected_offsets).
const ExpectedOffset = struct {
    name: []const u8,
    offset: comptime_int,
};

const request_offsets = [_]ExpectedOffset{
    .{ .name = "bytes", .offset = 0 },
    .{ .name = "length", .offset = 8 },
    .{ .name = "font_size", .offset = 16 },
    .{ .name = "proposed_main", .offset = 20 },
};

const result_offsets = [_]ExpectedOffset{
    .{ .name = "main", .offset = 0 },
    .{ .name = "cross", .offset = 4 },
};

const REQUEST_SIZE = 24;
const REQUEST_ALIGNMENT = 8;
const RESULT_SIZE = 8;
const RESULT_ALIGNMENT = 4;

/// Compile-time check of both contract structs against the frozen tables: size,
/// alignment, field count, and every field offset. Referenced from a top-level
/// `comptime {}` block AND re-asserted in a co-located test, so a drifted field
/// fails the native-test compile (and, transitively, the static-lib compile when
/// instance_seam.zig imports this module) before any runtime.
fn assertMeasureLayout() void {
    comptime {
        std.debug.assert(@sizeOf(MeasureRequest) == REQUEST_SIZE);
        std.debug.assert(@alignOf(MeasureRequest) == REQUEST_ALIGNMENT);
        std.debug.assert(@typeInfo(MeasureRequest).@"struct".fields.len == request_offsets.len);
        for (request_offsets) |entry| {
            std.debug.assert(@offsetOf(MeasureRequest, entry.name) == entry.offset);
        }
        std.debug.assert(@sizeOf(MeasureResult) == RESULT_SIZE);
        std.debug.assert(@alignOf(MeasureResult) == RESULT_ALIGNMENT);
        std.debug.assert(@typeInfo(MeasureResult).@"struct".fields.len == result_offsets.len);
        for (result_offsets) |entry| {
            std.debug.assert(@offsetOf(MeasureResult, entry.name) == entry.offset);
        }
    }
}

comptime {
    assertMeasureLayout();
}

/// A `pub` comptime entry so the outer instance_seam.zig root module can reference
/// the same frozen-layout gate from ITS top-level `comptime {}` block — then a
/// drifted offset fails the static-LIBRARY compile, not only this module's native
/// test. Mirrors instance_seam.assertInstanceLayout being referenced by its exports.
pub fn assertMeasureLayoutAtBuild() void {
    comptime assertMeasureLayout();
}

/// The decoupled carrier a text Node's MeasureCallback hands back to the seam
/// adapter (deviation d). It holds a POINTER to the seam-owned `?MeasureFn` slot
/// (so the callback value is read LIVE at measure time — set AFTER tree build with
/// no tree-walk patch) plus the node's font size (the Node field, captured at
/// build). It does NOT hold a *Seam, so this module never imports instance_seam.zig.
pub const MeasureContext = struct {
    measure_fn_slot: *const ?MeasureFn,
    font_size: f32,
};

/// The measure-pass adapter the seam installs as a text Node's `measure_callback`:
/// packs a MeasureRequest from the context's font size, the text bytes, and the
/// proposed wrap width, reads the LIVE callback from the slot (a CHECKED
/// `orelse unreachable` panic under .ReleaseSafe — guaranteed installed by the
/// install-order invariant), invokes it, and returns the result as a MeasuredSize.
/// The text slice is borrowed zero-copy for the duration of the call only.
pub fn measureThroughSeam(context: *anyopaque, text: []const u8, proposed_main: f32) MeasuredSize {
    const measure_context: *const MeasureContext = @ptrCast(@alignCast(context));
    const callback = measure_context.measure_fn_slot.* orelse unreachable;
    var request = MeasureRequest{
        .bytes = text.ptr,
        .length = text.len,
        .font_size = measure_context.font_size,
        .proposed_main = proposed_main,
    };
    var result: MeasureResult = undefined;
    callback(&request, &result);
    return .{ .main = result.main, .cross = result.cross };
}

const testing = std.testing;

test "the comptime layout tables match the request/result struct size, alignment, count, and every offset" {
    // The same assertion the build runs, re-asserted so `zig build test` (not only
    // the static-lib compile) fails on a drifted field.
    try testing.expectEqual(@as(usize, REQUEST_SIZE), @sizeOf(MeasureRequest));
    try testing.expectEqual(@as(usize, REQUEST_ALIGNMENT), @alignOf(MeasureRequest));
    try testing.expectEqual(request_offsets.len, @typeInfo(MeasureRequest).@"struct".fields.len);
    inline for (request_offsets) |entry| {
        try testing.expectEqual(@as(usize, entry.offset), @offsetOf(MeasureRequest, entry.name));
    }

    try testing.expectEqual(@as(usize, RESULT_SIZE), @sizeOf(MeasureResult));
    try testing.expectEqual(@as(usize, RESULT_ALIGNMENT), @alignOf(MeasureResult));
    try testing.expectEqual(result_offsets.len, @typeInfo(MeasureResult).@"struct".fields.len);
    inline for (result_offsets) |entry| {
        try testing.expectEqual(@as(usize, entry.offset), @offsetOf(MeasureResult, entry.name));
    }
}

/// A Zig stub MeasureFn standing in for the Swift Core Text callback in host-native
/// tests (deviation c): it echoes the request's font size into the result so a test
/// can prove the adapter packed the request faithfully and unpacked the result.
fn stubMeasure(request: *const MeasureRequest, result: *MeasureResult) callconv(.c) void {
    result.* = .{
        .main = @as(f32, @floatFromInt(request.length)) * request.font_size,
        .cross = request.font_size,
    };
}

test "the adapter packs the request from the context font size and the text and unpacks the result" {
    var slot: ?MeasureFn = stubMeasure;
    var context = MeasureContext{ .measure_fn_slot = &slot, .font_size = 13 };

    const measured = measureThroughSeam(&context, "abcd", 200);

    // The stub returns length * font_size for main and font_size for cross.
    try testing.expectEqual(@as(f32, 4 * 13), measured.main);
    try testing.expectEqual(@as(f32, 13), measured.cross);
}

test "the adapter reads the callback LIVE from the slot, so an install after context construction is seen" {
    var slot: ?MeasureFn = null;
    var context = MeasureContext{ .measure_fn_slot = &slot, .font_size = 10 };

    // The slot is installed AFTER the context was built (the Ф14 install-order: the
    // callback is set after the tree is built). Reading the slot live picks it up.
    slot = stubMeasure;
    const measured = measureThroughSeam(&context, "xyz", 0);

    try testing.expectEqual(@as(f32, 3 * 10), measured.main);
    try testing.expectEqual(@as(f32, 10), measured.cross);
}
