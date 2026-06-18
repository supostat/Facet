#include <metal_stdlib>
using namespace metal;

// GPU mirror of the Swift `struct Instance` (Instance.swift). The field order is
// the Р13 contract: nine floats then one uint, a 40-byte stride with no padding.
// Geometry is in drawable pixels, top-left origin; color is straight-alpha RGBA.
struct Instance {
    float positionX;
    float positionY;
    float width;
    float height;
    float colorR;
    float colorG;
    float colorB;
    float colorA;
    float cornerRadius;
    uint type;
};

struct VertexOut {
    float4 position [[position]];
    // Fragment-space coordinate centered on the rectangle, in pixels, so the
    // SDF is evaluated symmetrically about the center.
    float2 localPosition;
    float2 halfSize;
    float cornerRadius;
    float4 color;
};

// Two triangles covering the unit quad in [-0.5, 0.5], wound for the default
// front-facing order. Multiplying by the instance size and adding the center
// yields the pixel-space rectangle, expanded entirely on the GPU.
constant float2 quadCorners[6] = {
    float2(-0.5, -0.5),
    float2( 0.5, -0.5),
    float2( 0.5,  0.5),
    float2(-0.5, -0.5),
    float2( 0.5,  0.5),
    float2(-0.5,  0.5),
};

vertex VertexOut sdf_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    const device Instance* instances [[buffer(0)]],
    constant float2& drawableSize [[buffer(1)]]
) {
    const Instance instance = instances[instance_id];
    const float2 halfSize = float2(instance.width, instance.height) * 0.5;
    const float2 corner = quadCorners[vertex_id];
    const float2 localPosition = corner * float2(instance.width, instance.height);
    const float2 pixel = float2(instance.positionX, instance.positionY) + localPosition;

    // Pixel (top-left origin) -> NDC. Metal's NDC is bottom-left origin while the
    // texture/pixel grid is top-left, so Y is flipped here.
    const float ndcX = 2.0 * pixel.x / drawableSize.x - 1.0;
    const float ndcY = 1.0 - 2.0 * pixel.y / drawableSize.y;

    VertexOut out;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.localPosition = localPosition;
    out.halfSize = halfSize;
    // Clamp the radius to half the shorter side: a larger value would invert the
    // rounded corners. min(halfSize.x, halfSize.y) is the geometric upper bound.
    out.cornerRadius = min(instance.cornerRadius, min(halfSize.x, halfSize.y));
    out.color = float4(instance.colorR, instance.colorG, instance.colorB, instance.colorA);
    return out;
}

fragment float4 sdf_fragment(VertexOut in [[stage_in]]) {
    // Signed distance to a rounded box: standard formulation. q is the offset
    // from the inner (radius-shrunk) box corner; outside contributes a positive
    // length, inside contributes a negative interior term.
    const float radius = in.cornerRadius;
    const float2 q = abs(in.localPosition) - in.halfSize + radius;
    const float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;

    // Analytic antialiasing across one pixel of distance gradient.
    const float aa = fwidth(distance);
    const float coverage = 1.0 - smoothstep(-aa, aa, distance);

    // Premultiplied output to match the renderer's premultiplied blend state and
    // the .bgra8Unorm premultiplied readback layout.
    const float alpha = in.color.a * coverage;
    return float4(in.color.rgb * alpha, alpha);
}
