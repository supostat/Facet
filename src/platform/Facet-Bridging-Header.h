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

#endif
