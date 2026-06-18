#include <metal_stdlib>
using namespace metal;

// GPU mirror of the Swift `struct Instance` (Instance.swift). The field order is
// the Р13 contract: the first ten fields (positionX..type) are the frozen Phase 2
// body at offsets 0..36; the trailing twelve floats are the Phase 3 shadow +
// border, appended after `type` so the body offsets never move. The full stride
// is 88 bytes with no padding. Geometry is in drawable pixels, top-left origin;
// color and shadowColor are straight-alpha RGBA. Inert defaults (shadowColorA 0,
// borderThickness 0, blur 0, offset 0) reduce the composite exactly to Phase 2.
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
};

struct VertexOut {
    float4 position [[position]];
    // Fragment-space coordinate centered on the rectangle body, in pixels, so the
    // SDF is evaluated symmetrically about the body center. The quad is inflated
    // around this same center to make room for the shadow.
    float2 localPosition;
    // BODY half-extent (NOT the inflated quad), so the SDF measures the card.
    float2 halfSize;
    float cornerRadius;
    float4 color;
    float2 shadowOffset;
    float shadowBlurRadius;
    float4 shadowColor;
    float borderThickness;
    float4 borderColor;
};

// Two triangles covering the unit quad in [-0.5, 0.5], wound for the default
// front-facing order. Multiplying by the inflated instance size and adding the
// center yields the pixel-space rectangle, expanded entirely on the GPU.
constant float2 quadCorners[6] = {
    float2(-0.5, -0.5),
    float2( 0.5, -0.5),
    float2( 0.5,  0.5),
    float2(-0.5, -0.5),
    float2( 0.5,  0.5),
    float2(-0.5,  0.5),
};

// Signed distance to a rounded box centered at the origin: standard formulation.
// q is the offset from the inner (radius-shrunk) box corner; outside contributes
// a positive length, inside contributes a negative interior term. Shared by the
// body fill and the shadow silhouette so both edges round identically.
static float roundedBoxDistance(float2 point, float2 halfSize, float radius) {
    const float2 q = abs(point) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

vertex VertexOut sdf_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    const device Instance* instances [[buffer(0)]],
    constant float2& drawableSize [[buffer(1)]]
) {
    const Instance instance = instances[instance_id];
    const float2 halfSize = float2(instance.width, instance.height) * 0.5;
    const float2 shadowOffset = float2(instance.shadowOffsetX, instance.shadowOffsetY);

    // Inflate the quad by the shadow's reach so the soft, offset silhouette is
    // never clipped by the body-sized quad. Inert defaults leave inflation 0, so
    // the quad is byte-identical to Phase 2.
    const float2 inflation = float2(instance.shadowBlurRadius) + abs(shadowOffset);
    const float2 inflatedHalf = halfSize + inflation;

    const float2 corner = quadCorners[vertex_id];
    const float2 localPosition = corner * (inflatedHalf * 2.0);
    const float2 pixel = float2(instance.positionX, instance.positionY) + localPosition;

    // Pixel (top-left origin) -> NDC. Metal's NDC is bottom-left origin while the
    // texture/pixel grid is top-left, so Y is flipped here.
    const float ndcX = 2.0 * pixel.x / drawableSize.x - 1.0;
    const float ndcY = 1.0 - 2.0 * pixel.y / drawableSize.y;

    // Clamp the radius and border to half the shorter side: a larger value would
    // invert the rounded corners or overrun the body.
    const float maxExtent = min(halfSize.x, halfSize.y);

    VertexOut out;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.localPosition = localPosition;
    out.halfSize = halfSize;
    out.cornerRadius = min(instance.cornerRadius, maxExtent);
    out.color = float4(instance.colorR, instance.colorG, instance.colorB, instance.colorA);
    out.shadowOffset = shadowOffset;
    out.shadowBlurRadius = instance.shadowBlurRadius;
    out.shadowColor = float4(
        instance.shadowColorR, instance.shadowColorG, instance.shadowColorB, instance.shadowColorA);
    out.borderThickness = min(instance.borderThickness, maxExtent);
    out.borderColor = float4(
        instance.borderColorR, instance.borderColorG, instance.borderColorB, instance.borderColorA);
    return out;
}

fragment float4 sdf_fragment(VertexOut in [[stage_in]]) {
    // Soft drop shadow: the same rounded-box silhouette, shifted by the offset
    // and feathered across the blur half-width. No fwidth — the blur radius is
    // the intended softness, independent of screen-space derivatives.
    const float shadowDistance =
        roundedBoxDistance(in.localPosition - in.shadowOffset, in.halfSize, in.cornerRadius);
    const float blur = in.shadowBlurRadius;
    const float shadowCoverage = (blur > 0.0)
        ? 1.0 - smoothstep(-blur, blur, shadowDistance)
        : 1.0 - step(0.0, shadowDistance);
    const float shadowAlpha = in.shadowColor.a * shadowCoverage;
    const float4 shadowPremul = float4(in.shadowColor.rgb * shadowAlpha, shadowAlpha);

    // Body fill + border band. fillCoverage is the whole card; innerCoverage is
    // the card shrunk inward by the border thickness; the difference is the band.
    // borderThickness == 0 collapses the band, leaving innerCoverage ==
    // fillCoverage so bodyPremul reduces exactly to the Phase 2 fill expression.
    const float bodyDistance = roundedBoxDistance(in.localPosition, in.halfSize, in.cornerRadius);
    const float aa = fwidth(bodyDistance);
    const float fillCoverage = 1.0 - smoothstep(-aa, aa, bodyDistance);
    const float innerCoverage = 1.0 - smoothstep(-aa, aa, bodyDistance + in.borderThickness);
    const float borderCoverage = fillCoverage - innerCoverage;

    const float fillAlpha = in.color.a * innerCoverage;
    const float borderAlpha = in.borderColor.a * borderCoverage;
    const float4 fillPremul = float4(in.color.rgb * fillAlpha, fillAlpha);
    const float4 borderPremul = float4(in.borderColor.rgb * borderAlpha, borderAlpha);
    const float4 bodyPremul = fillPremul + borderPremul * (1.0 - fillPremul.a);

    // Composite the body OVER the shadow. Premultiplied output matches the
    // renderer's .one / .oneMinusSourceAlpha blend and the premultiplied readback.
    return bodyPremul + shadowPremul * (1.0 - bodyPremul.a);
}
