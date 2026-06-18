#include <metal_stdlib>
using namespace metal;

// Glyph rendering scaffold for the atlas path. A glyph quad samples its R8 alpha
// coverage from the atlas texture and multiplies it by a straight-alpha tint,
// emitting premultiplied output to match the renderer's .one /
// .oneMinusSourceAlpha "over" blend (the same blend the SDF path uses). This is
// linked into the SAME sdf.metallib as sdf.metal; the bench atlas viewer drives
// it, the production Renderer does not construct a glyph pipeline yet (that lands
// when a real glyph draw is issued).

// One glyph quad instance: a destination rectangle in drawable pixels (top-left
// origin), the atlas sub-rectangle in normalized [0,1] texture coordinates, and
// a straight-alpha RGBA tint. Field order is self-contained to this scaffold; it
// is not the Instance contract shared with sdf.metal.
struct GlyphQuad {
    float destinationX;
    float destinationY;
    float destinationWidth;
    float destinationHeight;
    float atlasMinU;
    float atlasMinV;
    float atlasMaxU;
    float atlasMaxV;
    float tintR;
    float tintG;
    float tintB;
    float tintA;
};

struct GlyphVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 tint;
};

// Unit-quad corners in [0, 1], two triangles. Multiplying by the destination
// size and adding the destination origin yields the pixel-space rectangle; the
// same parametric corner indexes the atlas sub-rectangle.
constant float2 quadCorners[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(1.0, 1.0),
    float2(0.0, 0.0),
    float2(1.0, 1.0),
    float2(0.0, 1.0),
};

vertex GlyphVertexOut glyph_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    const device GlyphQuad* quads [[buffer(0)]],
    constant float2& drawableSize [[buffer(1)]]
) {
    const GlyphQuad quad = quads[instance_id];
    const float2 corner = quadCorners[vertex_id];

    const float2 destinationOrigin = float2(quad.destinationX, quad.destinationY);
    const float2 destinationSize = float2(quad.destinationWidth, quad.destinationHeight);
    const float2 pixel = destinationOrigin + corner * destinationSize;

    // Pixel (top-left origin) -> NDC. Metal's NDC is bottom-left, so Y flips,
    // mirroring the SDF vertex shader.
    const float ndcX = 2.0 * pixel.x / drawableSize.x - 1.0;
    const float ndcY = 1.0 - 2.0 * pixel.y / drawableSize.y;

    const float2 atlasMin = float2(quad.atlasMinU, quad.atlasMinV);
    const float2 atlasMax = float2(quad.atlasMaxU, quad.atlasMaxV);

    GlyphVertexOut out;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.texCoord = atlasMin + corner * (atlasMax - atlasMin);
    out.tint = float4(quad.tintR, quad.tintG, quad.tintB, quad.tintA);
    return out;
}

fragment float4 glyph_fragment(
    GlyphVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    const float coverage = atlas.sample(atlasSampler, in.texCoord).r;
    const float alpha = in.tint.a * coverage;
    return float4(in.tint.rgb * alpha, alpha);
}
