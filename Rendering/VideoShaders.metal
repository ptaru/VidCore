//
//  VideoShaders.metal
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
// HDR Support - BT.2020 + PQ (SMPTE ST 2084) + BT.2390 Tone Mapping
// =============================================================================

struct ToneMappingParams {
    float inputMin;     // e.g. 0.0
    float inputMax;     // e.g. 1000.0 (content peak)
    float outputMin;    // e.g. 0.0
    float outputMax;    // e.g. 1000.0 (display peak) - if < inputMax, we tone map
};

// BT.2020 YCbCr to RGB matrix (non-constant luminance)
// ... (rest of existing matrix)
constant float3x3 bt2020NCMatrix = float3x3(
    float3(1.0,      1.0,      1.0),
    float3(0.0,     -0.1646,   1.8814),
    float3(1.4746,  -0.5714,   0.0)
);

// BT.2020 → Display P3 color gamut mapping matrix
constant float3x3 bt2020ToDisplayP3 = float3x3(
    float3( 1.2249,  -0.0420,  -0.0197),
    float3(-0.2247,   1.0424,  -0.0786),
    float3(-0.0002,  -0.0004,   1.0983)
);

// PQ constants
constant float pq_m1 = 0.1593017578125;
constant float pq_m2 = 78.84375;
constant float pq_c1 = 0.8359375;
constant float pq_c2 = 18.8515625;
constant float pq_c3 = 18.6875;

// PQ EOTF: PQ [0,1] -> Linear (nits)
float3 pqToLinear(float3 pq) {
    float3 p = pow(max(pq, 0.0), 1.0 / pq_m2);
    float3 num = max(p - pq_c1, 0.0);
    float3 den = pq_c2 - pq_c3 * p;
    return pow(num / max(den, 1e-6), 1.0 / pq_m1) * 10000.0;
}

// PQ Inverse EOTF: Linear (nits) -> PQ [0,1]
float3 linearToPQ(float3 linear) {
    float3 y = linear / 10000.0;
    float3 num = pq_c1 + pq_c2 * pow(y, pq_m1);
    float3 den = 1.0 + pq_c3 * pow(y, pq_m1);
    float3 n = pow(num / den, pq_m2);
    return n;
}

// Helper: Rescale absolute nits to [0, 1] relative to input range
float rescale_in(float x, constant ToneMappingParams& params) {
    return (x - params.inputMin) / (params.inputMax - params.inputMin);
}

// Helper: Rescale [0, 1] relative to output range back to absolute nits
float rescale_out(float x, constant ToneMappingParams& params) {
    return x * (params.outputMax - params.outputMin) + params.outputMin;
}

// ITU-R BT.2390 EETF (Electrical-Electrical Transfer Function)
// Based on standard implementation
float3 toneMapBT2390(float3 linearRGB, constant ToneMappingParams& params) {
    // If display is brighter than content, no tone mapping needed (conceptually)
    // Map when content peak > display peak
    if (params.outputMax >= params.inputMax) {
        return linearRGB;
    }

    // Work in PQ space for the hermite spline interpolation.
    // The reference implementation operates on 0.0-1.0 PQ-encoded signal.
    
    // Convert Linear Nits -> PQ
    float3 pq = linearToPQ(linearRGB);
    
    // Apply tone mapping curve to the max component to preserve hue.
    // ICtCp intensity is computationally expensive on GPU.
    
    float maxSig = max(pq.r, max(pq.g, pq.b));
    
    if (maxSig < 1e-6) return float3(0.0);

    // --- BT.2390 Algorithm (Scalar on maxSig) ---
    
    // Input/Output params are in NITS (Linear).
    // Convert Nits limits to PQ [0-1] range for the curve calculation.
    
    // Convert Nits limits to PQ limits
    // 10000 nits = 1.0 PQ
    float pqInputMin = 0.0; // Assuming 0 nits start
    float pqInputMax = linearToPQ(float3(params.inputMax)).r;
    float pqOutputMin = 0.0;
    float pqOutputMax = linearToPQ(float3(params.outputMax)).r;
    
    // rescale_in equivalent for current pixel val 'x' (which is 'maxSig')
    // range: [pqInputMin, pqInputMax] -> [0, 1]
    float x = (maxSig - pqInputMin) / (pqInputMax - pqInputMin);
    
    float minLum = (pqOutputMin - pqInputMin) / (pqInputMax - pqInputMin);
    float maxLum = (pqOutputMax - pqInputMin) / (pqInputMax - pqInputMin);
    
    // knee_offset default 1.0. 
    float offset = 1.0; 
    // Calculate knee point (ks) based on maxLum.
    // Using default offset = 1.0: ks = (1 + offset) * maxLum - offset = 2.0 * maxLum - 1.0
    float ks = (2.0 * maxLum) - 1.0; 
    
    float bp = minLum > 0 ? min(1.0 / minLum, 4.0) : 4.0;
    
    // gain_inv
    float gain_inv = 1.0 + (minLum / maxLum) * pow(1.0 - maxLum, bp);
    float gain = maxLum < 1.0 ? 1.0 / gain_inv : 1.0;
    
    float mappedX = x;

    // Piece-wise hermite spline
    if (ks < 1.0) {
        // if x > ks
        if (x > ks) {
            float tb = (x - ks) / (1.0 - ks);
            float tb2 = tb * tb;
            float tb3 = tb2 * tb;
            
            // Hermite polynomials
            // pb = (2t^3 - 3t^2 + 1) * ks + (t^3 - 2t^2 + t) * (1-ks) + (-2t^3 + 3t^2) * maxLum
            
            float term1 = (2.0 * tb3 - 3.0 * tb2 + 1.0) * ks;
            float term2 = (tb3 - 2.0 * tb2 + tb) * (1.0 - ks);
            float term3 = (-2.0 * tb3 + 3.0 * tb2) * maxLum;
            
            mappedX = term1 + term2 + term3;
        }
    }
    
    // Black point adaptation
    if (mappedX < 1.0) {
        mappedX += minLum * pow(1.0 - mappedX, bp);
        mappedX = gain * (mappedX - minLum) + minLum;
    }
    
    // Convert back to absolute PQ
    float pqMapped = mappedX * (pqInputMax - pqInputMin) + pqInputMin;
    
    // Apply gain to RGB
    // ratio = newMax / oldMax
    float ratio = pqMapped / maxSig;
    float3 pqToneMapped = pq * ratio;
    
    return pqToLinear(pqToneMapped);
}

// HDR Fragment shader for NV12/P010 10-bit bi-planar
// Y plane: texture(0) as r16Unorm, UV plane: texture(1) as rg16Unorm
fragment float4 hdrNV12FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]],
    constant ToneMappingParams& params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample 10-bit YUV
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // 10-bit video range conversion
    y = (y - 64.0/1023.0) * (1023.0/876.0);
    float u = (uv.x - 512.0/1023.0) * (1023.0/896.0);
    float v = (uv.y - 512.0/1023.0) * (1023.0/896.0);
    
    // BT.2020 YUV to RGB (result is still PQ-encoded, [0,1] range roughly)
    float3 rgbPQ = bt2020NCMatrix * float3(y, u, v);
    rgbPQ = max(rgbPQ, 0.0); // Clamp negative only

    // Pipeline: rgbPQ -> Linear -> ToneMap -> Linear Result.
    // Note: toneMapBT2390 accepts linear input for compatibility, even though it processes in PQ space.
    
    float3 linearSrc = pqToLinear(rgbPQ);
    
    // Apply Tone Mapping
    float3 linearToneMapped = toneMapBT2390(linearSrc, params);
    
    // Gamut mapping: BT.2020 → Display P3
    float3 linearDisplayP3 = bt2020ToDisplayP3 * linearToneMapped;
    
    // Output for macOS EDR (1.0 = 100 nits)
    return float4(linearDisplayP3 / 100.0, 1.0);
}

// HDR Fragment shader for I420/YUV420P10 10-bit tri-planar
fragment float4 hdrI420FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uTexture [[texture(1)]],
    texture2d<float> vTexture [[texture(2)]],
    constant ToneMappingParams& params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample 10-bit YUV
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float u = uTexture.sample(textureSampler, in.texCoord).r;
    float v = vTexture.sample(textureSampler, in.texCoord).r;
    
    // 10-bit video range conversion
    y = (y - 64.0/1023.0) * (1023.0/876.0);
    u = (u - 512.0/1023.0) * (1023.0/896.0);
    v = (v - 512.0/1023.0) * (1023.0/896.0);
    
    // BT.2020 YUV to RGB PQ
    float3 rgbPQ = bt2020NCMatrix * float3(y, u, v);
    rgbPQ = max(rgbPQ, 0.0);
    
    // Convert to Linear
    float3 linearSrc = pqToLinear(rgbPQ);
    
    // Tone Map
    float3 linearToneMapped = toneMapBT2390(linearSrc, params);
    
    // Gamut mapping
    float3 linearDisplayP3 = bt2020ToDisplayP3 * linearToneMapped;
    
    return float4(linearDisplayP3 / 100.0, 1.0);
}

// =============================================================================
// Dolby Vision Profile 5 (IPTPQc2) Support
// =============================================================================

// DoVi reshape component data - passed via separate buffer indices to stay under 4KB
// Each component (I, P, T) uses ~2.3KB
struct DoViReshapeComponent {
    float pivots[9];           // Pivot values normalized [0,1]
    float4 coeffs[8];          // x=c0/constant, y=c1/mmr_idx, z=c2, w=order (0=poly)
    float4 mmr[48];            // MMR coefficients (up to 8 pivots × 6 vec4s)
    uint numPivots;
    float _padding[3];         // Alignment padding
};

// DoVi color transformation parameters
// Layout must match Swift DoViParamsBuffer exactly
struct DoViParams {
    float4 nonlinearOffset;    // xyz = offset, w = unused (matches Swift SIMD4<Float>)
    float3x3 nonlinearMatrix;  // IPT → LMS matrix (ycc_to_rgb)
    float3x3 lms2rgbMatrix;    // Combined HPE inverse × rgb_to_lms
    float sourceMinPQ;         // For tone mapping
    float sourceMaxPQ;
    float _padding[2];
};

// Polynomial reshape: s_out = c2*s² + c1*s + c0
float doviReshapePoly(float s, float4 coeffs) {
    return (coeffs.z * s + coeffs.y) * s + coeffs.x;
}

// MMR reshape (order 1, 2, or 3)
// Uses cross-products of all three IPT channels
float doviReshapeMMR(float3 sig, float4 coeffs, constant float4 *mmr) {
    int mmr_idx = int(coeffs.y);
    int order = int(coeffs.w);
    
    // Cross-products: xy, xz, yz, xyz
    float4 sigX;
    sigX.xyz = sig.xxy * sig.yzz;  // (I*P, I*T, P*T)
    sigX.w = sigX.x * sig.z;       // I*P*T
    
    // Order 1: constant + linear + cross terms
    float s = coeffs.x;  // constant
    s += dot(mmr[mmr_idx + 0].xyz, sig);    // linear I, P, T
    s += dot(mmr[mmr_idx + 1], sigX);       // cross terms
    
    // Order 2: add quadratic terms
    if (order >= 2) {
        float3 sig2 = sig * sig;
        float4 sigX2 = sigX * sigX;
        s += dot(mmr[mmr_idx + 2].xyz, sig2);
        s += dot(mmr[mmr_idx + 3], sigX2);
        
        // Order 3: add cubic terms
        if (order >= 3) {
            s += dot(mmr[mmr_idx + 4].xyz, sig2 * sig);
            s += dot(mmr[mmr_idx + 5], sigX2 * sigX);
        }
    }
    return s;
}

// Select coefficient set based on signal value and pivot points
// Uses binary search via mix() for GPU efficiency
float4 doviSelectCoeffs(float s, constant DoViReshapeComponent& comp) {
    // Start with last interval's coefficients
    float4 result = comp.coeffs[max(int(comp.numPivots) - 2, 0)];
    
    // Binary search through pivots (unrolled for GPU)
    for (int i = int(comp.numPivots) - 3; i >= 0; i--) {
        result = mix(result, comp.coeffs[i], float4(s < comp.pivots[i + 1]));
    }
    return result;
}

// Reshape one component (I, P, or T)
float doviReshapeComponent(float3 sig, int c, constant DoViReshapeComponent& comp) {
    if (comp.numPivots < 2) return sig[c];  // No reshaping
    
    float s = sig[c];
    float4 coeffs = doviSelectCoeffs(s, comp);
    
    // coeffs.w == 0 means polynomial, otherwise MMR with that order
    if (coeffs.w == 0.0) {
        s = doviReshapePoly(s, coeffs);
    } else {
        s = doviReshapeMMR(sig, coeffs, comp.mmr);
    }
    
    return clamp(s, comp.pivots[0], comp.pivots[comp.numPivots - 1]);
}

// Full DoVi Profile 5 processing pipeline
// Reshape BEFORE matrix multiplication
float3 processDoVi(float3 ipt, constant DoViParams& params,
                   constant DoViReshapeComponent& compI,
                   constant DoViReshapeComponent& compP,
                   constant DoViReshapeComponent& compT) {
    
    // 1. RESHAPE (performed on raw I/P/T components FIRST)
    // Input is normalized [0,1] full-range IPT data
    float3 reshaped;
    reshaped.x = doviReshapeComponent(ipt, 0, compI);  // I channel
    reshaped.y = doviReshapeComponent(ipt, 1, compP);  // P channel
    reshaped.z = doviReshapeComponent(ipt, 2, compT);  // T channel
    
    // 2. NONLINEAR MATRIX (IPT → LMS, still in PQ domain)
    // Offset is SUBTRACTED (per reference black level handling)
    float3 lmsPQ = params.nonlinearMatrix * (reshaped - params.nonlinearOffset.xyz);
    
    // 3. PQ EOTF → Linear LMS
    float3 lmsLinear = pqToLinear(lmsPQ);
    
    // 4. LINEAR MATRIX (LMS → RGB in BT.2020)
    // Combined: HPE LMS→RGB inverse × rgb_to_lms from metadata
    float3 rgbLinear = params.lms2rgbMatrix * lmsLinear;
    
    // 5. PQ OETF → Back to PQ for tone mapper input
    return linearToPQ(rgbLinear);
}

// DoVi Profile 5 Fragment shader for NV12/P010 10-bit bi-planar
// Profile 5 content is ALWAYS full range - no limited range scaling!
fragment float4 doviNV12FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]],
    constant DoViParams& doviParams [[buffer(0)]],
    constant DoViReshapeComponent& compI [[buffer(1)]],
    constant DoViReshapeComponent& compP [[buffer(2)]],
    constant DoViReshapeComponent& compT [[buffer(3)]],
    constant ToneMappingParams& toneParams [[buffer(4)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample 10-bit IPT (Profile 5 is ALWAYS full range)
    // IPT values are all in [0,1] range after normalization
    float I = yTexture.sample(textureSampler, in.texCoord).r;
    float2 PT = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // IPT signal: all channels normalized to [0,1]
    // Do NOT subtract 0.5 from P/T like YCbCr - DoVi IPT is not chroma-centered!
    float3 ipt = float3(I, PT.x, PT.y);
    
    // DoVi processing → outputs PQ-encoded RGB in BT.2020
    float3 rgbPQ = processDoVi(ipt, doviParams, compI, compP, compT);
    
    // Convert to linear for tone mapping
    float3 linearSrc = pqToLinear(rgbPQ);
    
    // Apply BT.2390 tone mapping
    float3 linearToneMapped = toneMapBT2390(linearSrc, toneParams);
    
    // Gamut mapping: BT.2020 → Display P3
    float3 linearDisplayP3 = bt2020ToDisplayP3 * linearToneMapped;
    
    // Output for macOS EDR (1.0 = 100 nits)
    return float4(linearDisplayP3 / 100.0, 1.0);
}
