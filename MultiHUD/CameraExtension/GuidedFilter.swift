//
//  GuidedFilter.swift
//  CameraExtension
//
//  Edge-aware mask refinement using the Guided Image Filter (Kaiming He et al.).
//  Aligns mask edges to image boundaries for clean hair/finger compositing.
//

import CoreImage
import os

private let logger = Logger(subsystem: "net.fakeapps.MultiHUD.CameraExtension", category: "guidedfilter")

final class GuidedFilter {
    private let productsKernel: CIColorKernel
    private let coefficientsKernel: CIColorKernel
    private let outputKernel: CIColorKernel

    init?() {
        guard let url = Bundle(for: GuidedFilter.self).url(forResource: "default", withExtension: "metallib") else {
            logger.log("Guided filter metallib not found")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            logger.log("Failed to read metallib")
            return nil
        }
        do {
            productsKernel = try CIColorKernel(functionName: "guidedFilterProducts",
                                                fromMetalLibraryData: data)
            coefficientsKernel = try CIColorKernel(functionName: "guidedFilterCoefficients",
                                                    fromMetalLibraryData: data)
            outputKernel = try CIColorKernel(functionName: "guidedFilterOutput",
                                              fromMetalLibraryData: data)
            logger.log("Guided filter kernels loaded")
        } catch {
            logger.log("Failed to load guided filter kernels: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Refine a segmentation mask using the webcam frame as guide.
    /// - Parameters:
    ///   - guide: Webcam frame (BGRA CIImage, will be converted to grayscale internally)
    ///   - mask: Segmentation mask (single-channel or red-channel CIImage)
    ///   - radius: Box filter radius (default 8 — good for 720p)
    ///   - epsilon: Regularization (default 0.01 — moderate smoothing in flat regions)
    func apply(guide: CIImage, mask: CIImage, radius: Int = 8, epsilon: Float = 0.01) -> CIImage {
        let extent = mask.extent
        let r = NSNumber(value: radius)

        // Convert guide to grayscale (luminance in red channel)
        let gray = guide.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: extent)

        // Element-wise products: R = I*p, G = I*I
        guard let products = productsKernel.apply(extent: extent,
                                                   arguments: [gray, mask]) else {
            return mask
        }

        // Box filter all signals
        let meanI = gray.applyingFilter("CIBoxBlur", parameters: ["inputRadius": r])
            .cropped(to: extent)
        let meanP = mask.applyingFilter("CIBoxBlur", parameters: ["inputRadius": r])
            .cropped(to: extent)
        let meanProducts = products.applyingFilter("CIBoxBlur", parameters: ["inputRadius": r])
            .cropped(to: extent)

        // Compute coefficients: a = ..., b = ...
        guard let ab = coefficientsKernel.apply(extent: extent,
                                                 arguments: [meanI, meanP, meanProducts, epsilon]) else {
            return mask
        }

        // Smooth coefficients
        let meanAB = ab.applyingFilter("CIBoxBlur", parameters: ["inputRadius": r])
            .cropped(to: extent)

        // Final output: q = mean_a * I + mean_b
        guard let result = outputKernel.apply(extent: extent,
                                               arguments: [meanAB, gray]) else {
            return mask
        }

        return result.cropped(to: extent)
    }
}
