//
//  DoViRenderingShaders.metal
//  VidCore
//
//  Metal shaders for Dolby Vision Profile 5 to HDR10 conversion
//  Designed for System Renderer (AVSampleBufferDisplayLayer) interop
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

// DoVi reshape component data (matches SysDoViReshapeComponentBuffer)
struct SysDoViReshapeComponent {
    float pivots[9];           // Pivot values normalized [0,1]
    float4 coeffs[8];          // x=c0/constant, y=c1/mmr_idx, z=c2, w=order (0=poly)
    float4 mmr[48];            // MMR coefficients (up to 8 pivots × 6 vec4s)
    uint numPivots;
    float _padding[3];         // Alignment padding
};

// DoVi color transformation parameters (matches SysDoViParamsBuffer)
struct SysDoViParams {
    float4 nonlinearOffset;    // xyz = offset, w = unused
    float3x3 nonlinearMatrix;  // IPT → LMS matrix (ycc_to_rgb)
    float3x3 lms2rgbMatrix;    // Combined HPE inverse × rgb_to_lms
    float sourceMinPQ;         // For tone mapping
    float sourceMaxPQ;
    float _padding[2];
};

// MARK: - Helper Functions

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

// Polynomial reshape: s_out = c2*s² + c1*s + c0
float doviReshapePoly(float s, float4 coeffs) {
    return (coeffs.z * s + coeffs.y) * s + coeffs.x;
}

// MMR reshape (order 1, 2, or 3)
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
float4 doviSelectCoeffs(float s, constant SysDoViReshapeComponent& comp) {
    // Start with last interval's coefficients
    float4 result = comp.coeffs[max(int(comp.numPivots) - 2, 0)];
    
    // Binary search through pivots (unrolled)
    for (int i = int(comp.numPivots) - 3; i >= 0; i--) {
        result = mix(result, comp.coeffs[i], float4(s < comp.pivots[i + 1]));
    }
    return result;
}

// Reshape one component (I, P, or T)
float doviReshapeComponent(float3 sig, int c, constant SysDoViReshapeComponent& comp) {
    if (comp.numPivots < 2) return sig[c];  // No reshaping
    
    float s = sig[c];
    float4 coeffs = doviSelectCoeffs(s, comp);
    
    if (coeffs.w == 0.0) {
        s = doviReshapePoly(s, coeffs);
    } else {
        s = doviReshapeMMR(sig, coeffs, comp.mmr);
    }
    
    return clamp(s, comp.pivots[0], comp.pivots[comp.numPivots - 1]);
}

// Full DoVi Profile 5 processing pipeline
// Returns PQ-encoded BT.2020 RGB
float3 processDoVi(float3 ipt, constant SysDoViParams& params,
                   constant SysDoViReshapeComponent& compI,
                   constant SysDoViReshapeComponent& compP,
                   constant SysDoViReshapeComponent& compT) {
    
    // 1. RESHAPE (on raw I/P/T)
    float3 reshaped;
    reshaped.x = doviReshapeComponent(ipt, 0, compI);
    reshaped.y = doviReshapeComponent(ipt, 1, compP);
    reshaped.z = doviReshapeComponent(ipt, 2, compT);
    
    // 2. NONLINEAR MATRIX (IPT → LMS, PQ domain)
    float3 lmsPQ = params.nonlinearMatrix * (reshaped - params.nonlinearOffset.xyz);
    
    // 3. PQ EOTF → Linear LMS
    float3 lmsLinear = pqToLinear(lmsPQ);
    
    // 4. LINEAR MATRIX (LMS → RGB in BT.2020)
    float3 rgbLinear = params.lms2rgbMatrix * lmsLinear;
    
    // 5. PQ OETF → Back to PQ (native HDR10 format)
    return linearToPQ(rgbLinear);
}
// MARK: - Compute Kernels

// Convert Dolby Vision Profile 5 (NV12) to HDR10 (RGBA16Float)
// Input: NV12 textures (Y plane, UV plane)
// Output: RGBA16Float texture with PQ-encoded BT.2020 values [0, 1]

kernel void doviProfile5ToHDR10(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<float, access::write> outTexture [[texture(2)]],
    constant SysDoViParams& params [[buffer(0)]],
    constant SysDoViReshapeComponent& compI [[buffer(1)]],
    constant SysDoViReshapeComponent& compP [[buffer(2)]],
    constant SysDoViReshapeComponent& compT [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    
    // Profile 5 is Full Range 10-bit (IPTPQc2)
    // Metal unorm sampler normalizes [0, 1023] -> [0, 1]
    float I = yTexture.read(gid).r;
    float2 PT = uvTexture.read(gid / 2).rg;
    
    // Input is IPTPQc2 (I, P, T) in full range [0, 1]
    
    // Process DoVi -> Returns PQ-encoded BT.2020 RGB [0, 1]
    float3 rgbPQ = processDoVi(float3(I, PT.x, PT.y), params, compI, compP, compT);
    
    // Clamp
    rgbPQ = clamp(rgbPQ, 0.0, 1.0);
    
    // Write output (PQ encoded)
    outTexture.write(float4(rgbPQ, 1.0), gid);
}
