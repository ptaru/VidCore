//
//  YUVShaders.metal
//  VidCore
//
//  Metal shaders for GPU-accelerated YUV to RGB conversion
//  Eliminates CPU sws_scale overhead for NV12/YUV pixel buffers
//

#include <metal_stdlib>
using namespace metal;

// Vertex output structure
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen quad vertices (triangle strip)
constant float2 quadVertices[] = {
    float2(-1, -1),
    float2( 1, -1),
    float2(-1,  1),
    float2( 1,  1)
};

constant float2 quadTexCoords[] = {
    float2(0, 1),
    float2(1, 1),
    float2(0, 0),
    float2(1, 0)
};

// BT.709 color matrix for YUV to RGB conversion (HDTV standard)
// Assumes video range Y[16-235], UV[16-240]
constant float3x3 bt709Matrix = float3x3(
    float3(1.164,  1.164, 1.164),
    float3(0.0,   -0.213, 2.112),
    float3(1.793, -0.533, 0.0)
);

// Vertex shader - generates full-screen quad
vertex VertexOut yuvVertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(quadVertices[vertexID], 0, 1);
    out.texCoord = quadTexCoords[vertexID];
    return out;
}

// Fragment shader for NV12 (bi-planar YUV 4:2:0)
// Y plane: texture(0), UV plane (interleaved): texture(1)
fragment float4 nv12FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample Y (full resolution) and UV (half resolution, interleaved)
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // Convert from video range to full range
    y = (y - 16.0/255.0) * (255.0/219.0);
    float u = (uv.x - 128.0/255.0) * (255.0/224.0);
    float v = (uv.y - 128.0/255.0) * (255.0/224.0);
    
    // BT.709 YUV to RGB conversion
    float3 yuv = float3(y, u, v);
    float3 rgb = bt709Matrix * yuv;
    
    // Clamp to valid range
    rgb = saturate(rgb);
    
    return float4(rgb, 1.0);
}

// Fragment shader for NV12 Full Range (bi-planar YUV 4:2:0)
// Y plane: texture(0), UV plane (interleaved): texture(1)
// Uses FULL RANGE (0-255) - for content flagged as full range
fragment float4 nv12FullRangeFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample Y (full resolution) and UV (half resolution, interleaved)
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // Full range: Y is already in [0, 1], just offset UV
    float u = uv.x - 0.5;
    float v = uv.y - 0.5;
    
    // BT.709 full-range YUV to RGB conversion
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;
    
    // Clamp to valid range
    float3 rgb = saturate(float3(r, g, b));
    
    return float4(rgb, 1.0);
}

// Fragment shader for I420/YUV420P (tri-planar YUV 4:2:0)
// Y plane: texture(0), U plane: texture(1), V plane: texture(2)
// Uses VIDEO RANGE conversion (16-235) - default for most video content
fragment float4 i420FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uTexture [[texture(1)]],
    texture2d<float> vTexture [[texture(2)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample Y (full resolution) and U,V (half resolution, separate planes)
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float u = uTexture.sample(textureSampler, in.texCoord).r;
    float v = vTexture.sample(textureSampler, in.texCoord).r;
    
    // Convert from video range to full range
    y = (y - 16.0/255.0) * (255.0/219.0);
    u = (u - 128.0/255.0) * (255.0/224.0); // U is 0-255 in texture, but represents chroma
    v = (v - 128.0/255.0) * (255.0/224.0);
    
    // BT.709 YUV to RGB conversion
    float3 yuv = float3(y, u, v);
    float3 rgb = bt709Matrix * yuv;
    
    // Clamp to valid range
    rgb = saturate(rgb);
    
    return float4(rgb, 1.0);
}

// Fragment shader for I420/YUV420P Full Range (tri-planar YUV 4:2:0)
// Y plane: texture(0), U plane: texture(1), V plane: texture(2)
// Uses FULL RANGE conversion (0-255) - for specific full-range content
fragment float4 i420FullRangeFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uTexture [[texture(1)]],
    texture2d<float> vTexture [[texture(2)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample Y (full resolution) and U,V (half resolution, separate planes)
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float u = uTexture.sample(textureSampler, in.texCoord).r;
    float v = vTexture.sample(textureSampler, in.texCoord).r;
    
    // Full range conversion (no scaling needed for Y, just offset UV)
    // Y is already in [0, 1] range from texture sampler
    u = u - 0.5;  // UV centered at 128/255 ≈ 0.5
    v = v - 0.5;
    
    // BT.709 full-range YUV to RGB conversion matrix
    // R = Y + 1.5748 * V
    // G = Y - 0.1873 * U - 0.4681 * V
    // B = Y + 1.8556 * U
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;
    
    // Clamp to valid range
    float3 rgb = saturate(float3(r, g, b));
    
    return float4(rgb, 1.0);
}

// Fragment shader for BGRA (pass-through with scaling support)
fragment float4 bgraFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return texture.sample(textureSampler, in.texCoord);
}

// =============================================================================
// HDR Support - BT.2020 + PQ (SMPTE ST 2084)
// =============================================================================

// BT.2020 YCbCr to RGB matrix (non-constant luminance)
// Used for HDR10 content with BT.2020 color primaries
constant float3x3 bt2020NCMatrix = float3x3(
    float3(1.0,      1.0,      1.0),
    float3(0.0,     -0.1646,   1.8814),
    float3(1.4746,  -0.5714,   0.0)
);

// BT.2020 → Display P3 color gamut mapping matrix
// This is a chromatic adaptation using the Bradford transform
// Converts linear light from BT.2020 primaries to Display P3 primaries
// Derived from: DisplayP3_from_XYZ * Bradford * XYZ_from_BT2020
constant float3x3 bt2020ToDisplayP3 = float3x3(
    float3( 1.2249,  -0.0420,  -0.0197),
    float3(-0.2247,   1.0424,  -0.0786),
    float3(-0.0002,  -0.0004,   1.0983)
);


// PQ (SMPTE ST 2084) EOTF constants
// Converts PQ-encoded values to linear light in nits
constant float pq_m1 = 0.1593017578125;    // 2610 / 16384
constant float pq_m2 = 78.84375;           // 2523 / 32 * 128
constant float pq_c1 = 0.8359375;          // 3424 / 4096
constant float pq_c2 = 18.8515625;         // 2413 / 128
constant float pq_c3 = 18.6875;            // 2392 / 128

// PQ EOTF: Convert PQ-encoded signal [0,1] to linear light [0, 10000] nits
float3 pqToLinear(float3 pq) {
    float3 p = pow(max(pq, 0.0), 1.0 / pq_m2);
    float3 num = max(p - pq_c1, 0.0);
    float3 den = pq_c2 - pq_c3 * p;
    return pow(num / max(den, 1e-6), 1.0 / pq_m1) * 10000.0;
}

// HDR Fragment shader for NV12/P010 10-bit bi-planar
// Y plane: texture(0) as r16Unorm, UV plane: texture(1) as rg16Unorm
// Outputs linear light in Display P3 for EDR (1.0 = SDR white at 100 nits)
fragment float4 hdrNV12FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample 10-bit YUV (normalized to [0,1] by texture sampler)
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // 10-bit video range conversion:
    // Y: [64, 940] / 1023 -> [0, 1]
    // UV: [64, 960] / 1023, centered at 512/1023
    y = (y - 64.0/1023.0) * (1023.0/876.0);
    float u = (uv.x - 512.0/1023.0) * (1023.0/896.0);
    float v = (uv.y - 512.0/1023.0) * (1023.0/896.0);
    
    // BT.2020 YUV to RGB (result is still PQ-encoded)
    float3 rgb = bt2020NCMatrix * float3(y, u, v);
    rgb = saturate(rgb);
    
    // PQ EOTF: Convert to linear light (nits) in BT.2020 primaries
    float3 linearBT2020 = pqToLinear(rgb);
    
    // Gamut mapping: BT.2020 → Display P3
    // This preserves color relationships while mapping to the display's color volume
    float3 linearDisplayP3 = bt2020ToDisplayP3 * linearBT2020;
    
    // Output for macOS EDR: 1.0 = SDR reference white (100 nits)
    // Values > 1.0 are HDR highlights
    return float4(linearDisplayP3 / 100.0, 1.0);
}

// HDR Fragment shader for I420/YUV420P10 10-bit tri-planar
// Y plane: texture(0), U plane: texture(1), V plane: texture(2) - all r16Unorm
// Outputs linear light in Display P3 for EDR (1.0 = SDR white at 100 nits)
fragment float4 hdrI420FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uTexture [[texture(1)]],
    texture2d<float> vTexture [[texture(2)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample 10-bit YUV (normalized to [0,1] by texture sampler)
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float u = uTexture.sample(textureSampler, in.texCoord).r;
    float v = vTexture.sample(textureSampler, in.texCoord).r;
    
    // 10-bit video range conversion
    y = (y - 64.0/1023.0) * (1023.0/876.0);
    u = (u - 512.0/1023.0) * (1023.0/896.0);
    v = (v - 512.0/1023.0) * (1023.0/896.0);
    
    // BT.2020 YUV to RGB (result is still PQ-encoded)
    float3 rgb = bt2020NCMatrix * float3(y, u, v);
    rgb = saturate(rgb);
    
    // PQ EOTF: Convert to linear light (nits) in BT.2020 primaries
    float3 linearBT2020 = pqToLinear(rgb);
    
    // Gamut mapping: BT.2020 → Display P3
    float3 linearDisplayP3 = bt2020ToDisplayP3 * linearBT2020;
    
    // Output for macOS EDR: 1.0 = SDR reference white (100 nits)
    // Values > 1.0 are HDR highlights
    return float4(linearDisplayP3 / 100.0, 1.0);
}
