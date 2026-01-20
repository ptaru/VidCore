//
//  VideoShaders.metal
//  VidCore
//
//  Metal shaders for GPU-accelerated YUV to RGB conversion
//  Eliminates CPU sws_scale overhead for NV12/YUV pixel buffers
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Structures & Constants

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

// BT.709 Full Range Matrix (YUV [0,1] -> RGB)
constant float3x3 bt709FullRangeMatrix = float3x3(
    float3(1.0,    1.0,    1.0),
    float3(0.0,   -0.1873, 1.8556),
    float3(1.5748, -0.4681, 0.0)
);

// MARK: - Video Range Conversion Helpers

// Video Range Y (8-bit) [16, 235] -> [0, 1]
inline float videoRangeY8(float y) {
    return (y - 16.0/255.0) * (255.0/219.0);
}

// Video Range UV (8-bit) [16, 240] -> [-0.5, 0.5]
inline float videoRangeUV8(float uv) {
    return (uv - 128.0/255.0) * (255.0/224.0);
}

// Video Range Y (10-bit) [64, 940] -> [0, 1]
inline float videoRangeY10(float y) {
    return (y - 64.0/1024.0) * (1024.0/876.0);
}

// Video Range UV (10-bit) [64, 960] -> [-0.5, 0.5]
inline float videoRangeUV10(float uv) {
    return (uv - 512.0/1024.0) * (1024.0/896.0);
}

// MARK: - Vertex Shaders

vertex VertexOut yuvVertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(quadVertices[vertexID], 0, 1);
    out.texCoord = quadTexCoords[vertexID];
    return out;
}

// MARK: - SDR Fragment Shaders

// NV12 (Bi-planar YUV 4:2:0) - Video Range
fragment float4 nv12FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // Convert to full range
    float3 yuv = float3(videoRangeY8(y), videoRangeUV8(uv.x), videoRangeUV8(uv.y));
    float3 rgb = bt709FullRangeMatrix * yuv;
    
    return float4(saturate(rgb), 1.0);
}

// NV12 Full Range (Bi-planar 4:2:0)
fragment float4 nv12FullRangeFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // Y is [0, 1], offset UV
    float u = uv.x - 0.5;
    float v = uv.y - 0.5;
    
    // BT.709 full-range YUV to RGB conversion
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;
    
    float3 rgb = saturate(float3(r, g, b));
    
    return float4(rgb, 1.0);
}

// I420 (Tri-planar YUV 4:2:0) - Video Range
fragment float4 i420FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uTexture [[texture(1)]],
    texture2d<float> vTexture [[texture(2)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float u = uTexture.sample(textureSampler, in.texCoord).r;
    float v = vTexture.sample(textureSampler, in.texCoord).r;
    
    // Convert to full range
    float3 yuv = float3(videoRangeY8(y), videoRangeUV8(u), videoRangeUV8(v));
    float3 rgb = bt709FullRangeMatrix * yuv;
    
    return float4(saturate(rgb), 1.0);
}

// I420 Full Range (Tri-planar 4:2:0)
fragment float4 i420FullRangeFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uTexture [[texture(1)]],
    texture2d<float> vTexture [[texture(2)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float u = uTexture.sample(textureSampler, in.texCoord).r;
    float v = vTexture.sample(textureSampler, in.texCoord).r;
    
    // Full range (offset UV)
    // Y is already [0, 1]
    u = u - 0.5;
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

// BGRA Pass-through
fragment float4 bgraFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return texture.sample(textureSampler, in.texCoord);
}

// =============================================================================
// MARK: - HDR Maths Helpers (BT.2020 + PQ + BT.2390)
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
    float3( 1.34357825, -0.06529745,  0.00282179),
    float3(-0.28217967,  1.07578792, -0.01959849),
    float3(-0.06139858, -0.01049046,  1.01677671)
);

// Display P3 → BT.2020 matrix (Inverse of above)
constant float3x3 displayP3ToBT2020Matrix = float3x3(
    float3( 0.753833,  0.045744, -0.001210), // Column 1
    float3( 0.198597,  0.941777,  0.017601), // Column 2
    float3( 0.047570,  0.012479,  0.983609)  // Column 3
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
float3 toneMapBT2390(float3 pq, constant ToneMappingParams& params) {
    // If display is brighter than content, no tone mapping needed (conceptually)
    // Map when content peak > display peak
    if (params.outputMax >= params.inputMax) {
        return pqToLinear(pq);
    }

     // Work in PQ space for hermite spline interpolation (0.0-1.0 signal)
    
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
    
    // knee_offset
    float ks = (1.5 * maxLum) - 0.5; 
    
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

// MARK: - HDR Processing Helper

// Processes PQ-encoded BT.2020 RGB through tone mapping and gamut conversion
// sdrOutput: false = EDR output (linear/100), true = SDR output (gamma 2.2)
inline float4 processHDROutput(float3 rgbPQ, constant ToneMappingParams& params, bool sdrOutput) {
    // Clamp negative values
    rgbPQ = max(rgbPQ, 0.0);
    
    // BT.2390 tone mapping (PQ domain)
    float3 linearToneMapped = toneMapBT2390(rgbPQ, params);
    
    // Gamut mapping: BT.2020 → Display P3
    float3 linearDisplayP3 = bt2020ToDisplayP3 * linearToneMapped;
    
    if (sdrOutput) {
        // SDR: normalize to 100 nits and apply gamma 2.2
        float3 sRGB = pow(saturate(linearDisplayP3 / 100.0), 1.0 / 2.2);
        return float4(sRGB, 1.0);
    }
    
    // EDR: output linear where 1.0 = 100 nits
    return float4(linearDisplayP3 / 100.0, 1.0);
}

// MARK: - HDR Fragment Shaders

// HDR NV12 (10-bit Bi-planar)
// Y: r16Unorm, UV: rg16Unorm
fragment float4 hdrNV12FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]],
    constant ToneMappingParams& params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample 10-bit YUV and convert from video range
    float y = videoRangeY10(yTexture.sample(textureSampler, in.texCoord).r);
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    float u = videoRangeUV10(uv.x);
    float v = videoRangeUV10(uv.y);
    
    // BT.2020 YUV to RGB PQ, then HDR processing
    float3 rgbPQ = bt2020NCMatrix * float3(y, u, v);
    return processHDROutput(rgbPQ, params, false);
}

// HDR I420 (10-bit Tri-planar)
fragment float4 hdrI420FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uTexture [[texture(1)]],
    texture2d<float> vTexture [[texture(2)]],
    constant ToneMappingParams& params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample 10-bit YUV and convert from video range
    float y = videoRangeY10(yTexture.sample(textureSampler, in.texCoord).r);
    float u = videoRangeUV10(uTexture.sample(textureSampler, in.texCoord).r);
    float v = videoRangeUV10(vTexture.sample(textureSampler, in.texCoord).r);
    
    // BT.2020 YUV to RGB PQ, then HDR processing
    float3 rgbPQ = bt2020NCMatrix * float3(y, u, v);
    return processHDROutput(rgbPQ, params, false);
}


// =============================================================================
// MARK: - HLG (Hybrid Log-Gamma / ARIB STD-B67 / BT.2100 HLG)
// =============================================================================

// HLG constants from ITU-R BT.2100
constant float hlg_a = 0.17883277;
constant float hlg_b = 0.28466892;
constant float hlg_c = 0.55991073;

// HLG OETF^-1: HLG signal [0,1] -> Scene-linear [0,1]
float3 hlgOETFInverse(float3 hlg) {
    return mix(
        hlg * hlg / 3.0,
        (exp((hlg - hlg_c) / hlg_a) + hlg_b) / 12.0,
        step(0.5, hlg)
    );
}

// HLG OOTF: Scene-linear -> Display-linear
// Uses precise BT.2100 Table 5 formula with log10
float3 hlgOOTF(float3 sceneLinear, float displayPeak) {
    float gamma = 1.2 + 0.42 * log10(displayPeak / 1000.0);
    float Ys = dot(float3(0.2627, 0.6780, 0.0593), sceneLinear);
    return displayPeak * pow(max(Ys, 1e-6), gamma - 1.0) * sceneLinear;
}

// Combined HLG to linear: OETF^-1 then OOTF
float3 hlgToLinear(float3 hlg, float displayPeak) {
    float3 sceneLinear = hlgOETFInverse(hlg);
    return hlgOOTF(sceneLinear, displayPeak);
}

// Processes HLG-encoded BT.2020 RGB using "Reference + Tone Map" strategy:
// 1. Render to fixed 1000-nit reference (consistent gamma across displays)
// 2. Convert to PQ and apply BT.2390 tone mapping
// 3. Gamut map to Display P3
inline float4 processHLGOutput(float3 rgbHLG, constant ToneMappingParams& params, bool sdrOutput) {
    rgbHLG = max(rgbHLG, 0.0);
    
    // 1. Render to 1000-nit REFERENCE (consistent gamma)
    float3 linearReference = hlgToLinear(rgbHLG, 1000.0);
    
    // 2. Convert to PQ domain for BT.2390 tone mapping
    float3 pqReference = linearToPQ(linearReference);
    
    // 3. Apply BT.2390 tone mapping (returns linear nits)
    //    params.inputMax = 1000.0 (HLG reference), params.outputMax = display peak
    float3 linearToneMapped = toneMapBT2390(pqReference, params);
    
    // 4. Gamut mapping: BT.2020 → Display P3
    float3 linearDisplayP3 = bt2020ToDisplayP3 * linearToneMapped;
    
    if (sdrOutput) {
        return float4(pow(saturate(linearDisplayP3 / 100.0), 1.0 / 2.2), 1.0);
    }
    return float4(linearDisplayP3 / 100.0, 1.0);
}

// HLG NV12 (10-bit Bi-planar)
fragment float4 hlgNV12FragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> uvTexture [[texture(1)]],
    constant ToneMappingParams& params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float y = videoRangeY10(yTexture.sample(textureSampler, in.texCoord).r);
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;
    float3 rgbHLG = bt2020NCMatrix * float3(y, videoRangeUV10(uv.x), videoRangeUV10(uv.y));
    return processHLGOutput(rgbHLG, params, false);
}



// =============================================================================
// MARK: - Dolby Vision Profile 5 (IPTPQc2) Implementation
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
// Uses linear scan (not binary search) for GPU efficiency (branchless mix)
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

// MARK: - Dolby Vision Fragment Shaders

// DoVi Profile 5 NV12 (10-bit Bi-planar)
// Profile 5 is always full range
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
    float I = yTexture.sample(textureSampler, in.texCoord).r;
    float2 PT = uvTexture.sample(textureSampler, in.texCoord).rg;
    
    // DoVi processing → outputs PQ-encoded RGB in BT.2020
    float3 rgbPQ = processDoVi(float3(I, PT.x, PT.y), doviParams, compI, compP, compT);
    
    // HDR processing with EDR output
    return processHDROutput(rgbPQ, toneParams, false);
}

// Generic Tone Mapping Shader (Linear P3 -> SDR)
// Takes an EDR texture (Linear P3, where 1.0 = 100 nits) and tone maps to SDR (BGRA8)
fragment float4 toneMapSDRFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> inputTexture [[texture(0)]],
    constant ToneMappingParams& toneParams [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // 1. Sample Linear P3 EDR input
    float4 rgba = inputTexture.sample(textureSampler, in.texCoord);
    float3 linearP3 = rgba.rgb; // 1.0 = 100 nits
    
    // 2. Convert to Linear BT.2020 (required for PQ conversion)
    float3 linearBT2020 = displayP3ToBT2020Matrix * linearP3;
    
    // 3. Convert to PQ BT.2020 (0-1 range) for tone mapping
    // linearToPQ expects input in 10000 nits scale, so multiply by 100
    // (since our EDR is normalized to 100 nits = 1.0)
    float3 pqBT2020 = linearToPQ(linearBT2020 * 100.0);
    
    // 4. Run through standard HDR output processing with sdrOutput=true
    return processHDROutput(pqBT2020, toneParams, true);
}
