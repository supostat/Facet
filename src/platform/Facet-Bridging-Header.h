#ifndef FACET_BRIDGING_HEADER_H
#define FACET_BRIDGING_HEADER_H

#include <stdint.h>
#include <stdbool.h>

// The C mirror of the Zig `Instance` extern struct (instances.zig) and the Swift
// `struct Instance` (Instance.swift) — three types over the same 104 bytes. The
// field names, types, and order are the Р13 contract; the Zig comptime layout
// assertion and the Bridge precondition both pin MemoryLayout<FacetInstance>.stride
// == MemoryLayout<Instance>.stride == 104. The field names are camelCase (the Р13
// cross-language exception to snake_case). `type` cannot be a C field name keyword
// conflict — it is a plain identifier in C — so it stays `type` to match Zig/Swift.
typedef struct {
    float positionX;
    float positionY;
    float width;
    float height;
    float colorR;
    float colorG;
    float colorB;
    float colorA;
    float cornerRadius;
    uint32_t type;
    float shadowOffsetX;
    float shadowOffsetY;
    float shadowBlurRadius;
    float shadowColorR;
    float shadowColorG;
    float shadowColorB;
    float shadowColorA;
    float borderThickness;
    float borderColorR;
    float borderColorG;
    float borderColorB;
    float borderColorA;
    float atlasMinU;
    float atlasMinV;
    float atlasMaxU;
    float atlasMaxV;
} FacetInstance;

// The C mirror of the Zig `MeasureRequest`/`MeasureResult` extern structs
// (measure_seam.zig) — the UPWARD half of the lower seam (Ф14, Р10). The Zig core
// asks Swift to measure a text run with real Core Text and reads metrics back. The
// field names, types, and order are the frozen contract pinned by the Zig comptime
// layout assertion (MeasureRequest 24 bytes / 8-align, offsets {bytes:0, length:8,
// font_size:16, proposed_main:20}; MeasureResult 8 bytes / 4-align, {main:0,
// cross:4}). The `bytes` pointer is a zero-copy borrow valid only within the call —
// Swift decodes a String and never retains it.
typedef struct {
    const uint8_t *bytes;
    size_t length;
    float font_size;
    float proposed_main;
} FacetMeasureRequest;

typedef struct {
    float main;
    float cross;
} FacetMeasureResult;

// The measure callback Swift installs into the seam: given a request, fill a
// result. Invoked by the Zig measure pass on a cache miss (a real Zig->Swift
// crossing); a cache hit bypasses it (the anti-chatty-seam guarantee).
typedef void (*FacetMeasureCallback)(const FacetMeasureRequest *request, FacetMeasureResult *result);

// The C mirror of the Zig `ShapeRequest`/`PlacedGlyphExtern` extern structs
// (shape_seam.zig) — the SECOND upward half of the lower seam (Ф14, Р10), the
// VARIABLE-LENGTH mirror of the measure seam. The Zig core asks Swift to shape a
// text run with real Core Text and reads the per-glyph geometry back. The field
// names, types, and order are the frozen contract pinned by the Zig comptime layout
// assertion (FacetShapeRequest 32 bytes / 8-align, offsets {bytes:0, length:8,
// font_size:16, origin_x:20, origin_y:24, proposed_wrap_width:28}; FacetPlacedGlyph
// 32 bytes / 4-align == tree.PlacedGlyph, offsets {center_x:0 .. atlas_max_v:28}).
// The `bytes` pointer is a zero-copy borrow valid only within the call. origin is
// the text node's ABSOLUTE laid-out top-left (PlacedGlyph centers are absolute);
// proposed_wrap_width is carried but UNUSED (single-line, no wrap shaper yet).
typedef struct {
    const uint8_t *bytes;
    size_t length;
    float font_size;
    float origin_x;
    float origin_y;
    float proposed_wrap_width;
} FacetShapeRequest;

typedef struct {
    float center_x;
    float center_y;
    float width;
    float height;
    float atlas_min_u;
    float atlas_min_v;
    float atlas_max_u;
    float atlas_max_v;
} FacetPlacedGlyph;

// The shape callback Swift installs into the seam: given a request, write up to
// `capacity` glyphs into the destination buffer and return the count written (>= 0),
// or -(required + 1) (<= -1) when the capacity is too small so Zig grows its
// seam-owned scratch and re-calls (mirrors give-instances' count-or-overflow
// encoding). Invoked once per unshaped text node per static scene (the anti-chatty
// shape seam).
typedef long (*FacetShapeCallback)(const FacetShapeRequest *request, FacetPlacedGlyph *destination, long capacity);

// The C decls for the Zig callconv(.c) exports (instance_seam.zig). The seam owns
// the shadow tree + instance producer behind an opaque handle; Swift drives the
// per-frame has-changed -> give-instances loop and hands a StorageModeShared
// MTLBuffer base so the seam writes instances straight into GPU-visible memory.

// Allocate a seam handle (null on allocation failure).
void *facet_seam_create(void);

// Free a seam handle and everything it owns. A null handle is a no-op.
void facet_seam_destroy(void *handle);

// Record the GPU-visible instance buffer span. Rejects a null base or zero
// capacity with a negative status; returns 0 on success.
int facet_seam_set_base_pointer(void *handle, FacetInstance *base, uint32_t capacity);

// Lay out the tree rooted at root_id into a width x height drawable and write the
// instance array into the recorded base. Returns the instance count (>= 0) on a
// fitting write, or -(required + 1) (<= -1) when the buffer is too small so the
// caller grows and re-hands the base; a missing target / unknown root is -1.
long facet_seam_give_instances(void *handle, uint32_t root_id, float width, float height);

// Whether the tree changed since the last produce (the frame loop's has-changed
// gate). True on the first frame so the tree draws exactly once.
bool facet_seam_has_changed(void *handle);

// Build the КТ-2 / e2e reference tree, returning its root id (UINT32_MAX on
// allocation failure).
uint32_t facet_seam_build_reference_tree(void *handle);

// Apply a paint-only mutation to the reference tree (a recolor) and bump the
// change epoch so the next has-changed reports a change.
void facet_seam_mutate_reference(void *handle);

// The node count the last give-instances recomputed (a frame-stat input; 0 on a
// static frame).
uint32_t facet_seam_last_recomputed(void *handle);

// The instance count the last give-instances wrote (the draw count to re-bind on a
// static frame without re-producing).
uint32_t facet_seam_last_count(void *handle);

// Install the Ф14 measure callback (the Swift Core Text seam) into the seam's live
// slot. Rejects a null fn / null handle with a negative status; returns 0 on
// success. MUST be called before the first give-instances that measures the scene.
int facet_seam_set_measure_callback(void *handle, FacetMeasureCallback callback);

// The count of real Zig->Swift measure crossings so far (cache misses). A repeated
// (string, width) is a cache hit that bypasses the seam, so this stays 1 across two
// produces of the static measure scene. 0 on a null handle.
uint32_t facet_seam_measure_crossings(void *handle);

// Build the Ф14 measure scene — a fit-content container hugging a single text leaf
// sized by the measure seam — returning its root id (UINT32_MAX on allocation
// failure). Separate from the Phase-13 reference tree.
uint32_t facet_seam_build_measure_tree(void *handle);

// The seam-measured main-axis extent of a node (the laid-out rect width of node_id;
// the measure scene's label container is a row, so main == width). After a produce
// this hugs the real Core-Text-measured text width. 0 on a null handle / unknown id.
float facet_seam_node_laid_out_main(void *handle, uint32_t node_id);

// Install the Phase-14b shape callback (the Swift Core Text seam) into the seam's
// live slot. Rejects a null fn / null handle with a negative status; returns 0 on
// success. MUST be called before the first give-instances that shapes the scene.
int facet_seam_set_shape_callback(void *handle, FacetShapeCallback callback);

// The count of real Zig->Swift shape crossings so far. A static scene shapes its
// text leaf once, so this stays 1 across two produces (the anti-chatty shape seam).
// 0 on a null handle.
uint32_t facet_seam_shape_crossings(void *handle);

#endif
