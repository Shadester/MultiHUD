//
//  GuidedFilter.metal
//  CameraExtension
//
//  CIColorKernel functions for guided image filtering.
//  Used for edge-aware mask refinement: aligns mask edges to image boundaries.
//

#include <CoreImage/CoreImage.h>

extern "C" {

    /// Computes element-wise products for guided filter:
    ///   R = guide.r * mask.r  (I·p)
    ///   G = guide.r * guide.r (I·I)
    float4 guidedFilterProducts(coreimage::sample_t guide,
                                 coreimage::sample_t mask,
                                 coreimage::destination dest) {
        float I = guide.x;
        float p = mask.x;
        return float4(I * p, I * I, 0.0, 1.0);
    }

    /// Computes guided filter coefficients from box-filtered means:
    ///   a = (mean_Ip - mean_I * mean_p) / (mean_II - mean_I^2 + eps)
    ///   b = mean_p - a * mean_I
    /// Output: R = a, G = b
    float4 guidedFilterCoefficients(coreimage::sample_t meanI,
                                     coreimage::sample_t meanP,
                                     coreimage::sample_t meanProducts,
                                     float epsilon,
                                     coreimage::destination dest) {
        float mI  = meanI.x;
        float mP  = meanP.x;
        float mIp = meanProducts.x;
        float mII = meanProducts.y;

        float varI = mII - mI * mI;
        float a = (mIp - mI * mP) / (varI + epsilon);
        float b = mP - a * mI;
        return float4(a, b, 0.0, 1.0);
    }

    /// Final guided filter output: q = mean_a * I + mean_b
    float4 guidedFilterOutput(coreimage::sample_t meanAB,
                               coreimage::sample_t guide,
                               coreimage::destination dest) {
        float q = meanAB.x * guide.x + meanAB.y;
        return float4(q, q, q, 1.0);
    }
}
