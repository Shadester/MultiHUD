//
//  RVMMatting.swift
//  CameraExtension
//
//  Robust Video Matting via CoreML. Produces true alpha mattes with
//  built-in temporal consistency (ConvGRU hidden states).
//  Falls back gracefully — init returns nil if the model isn't bundled.
//

import CoreML
import CoreImage
import CoreVideo
import os

private let logger = Logger(subsystem: "net.fakeapps.MultiHUD.CameraExtension", category: "rvm")

final class RVMMatting {
    private var model: MLModel
    private var r1: MLMultiArray?
    private var r2: MLMultiArray?
    private var r3: MLMultiArray?
    private var r4: MLMultiArray?

    /// Current model resolution tag ("720p" or "1080p").
    private(set) var resolution: String

    private static let model720p = "rvm_mobilenetv3_1280x720_s0.375_fp16"
    private static let model1080p = "rvm_mobilenetv3_1920x1080_s0.25_fp16"

    init?(resolution: String = "720p") {
        let modelName = resolution == "1080p" ? Self.model1080p : Self.model720p
        guard let url = Bundle(for: RVMMatting.self).url(forResource: modelName, withExtension: "mlmodelc")
                ?? Bundle(for: RVMMatting.self).url(forResource: modelName, withExtension: "mlmodel") else {
            logger.log("RVM model not found: \(modelName, privacy: .public)")
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: config) else {
            logger.log("Failed to load RVM model: \(modelName, privacy: .public)")
            return nil
        }
        self.model = model
        self.resolution = resolution
        logger.log("RVM loaded: \(modelName, privacy: .public)")
    }

    /// Switch to a different resolution model. Resets hidden states.
    func switchResolution(_ newResolution: String) -> Bool {
        guard newResolution != resolution else { return true }
        let modelName = newResolution == "1080p" ? Self.model1080p : Self.model720p
        guard let url = Bundle(for: RVMMatting.self).url(forResource: modelName, withExtension: "mlmodelc")
                ?? Bundle(for: RVMMatting.self).url(forResource: modelName, withExtension: "mlmodel") else {
            return false
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let newModel = try? MLModel(contentsOf: url, configuration: config) else {
            return false
        }
        model = newModel
        resolution = newResolution
        reset()
        logger.log("RVM switched to \(modelName, privacy: .public)")
        return true
    }

    /// Run inference on a camera frame. Returns alpha matte as CIImage (grayscale).
    func predict(pixelBuffer: CVPixelBuffer) -> CIImage? {
        let provider = RVMInputProvider(src: pixelBuffer, r1: r1, r2: r2, r3: r3, r4: r4)
        guard let output = try? model.prediction(from: provider) else { return nil }

        // Update recurrent states
        r1 = output.featureValue(for: "r1o")?.multiArrayValue
        r2 = output.featureValue(for: "r2o")?.multiArrayValue
        r3 = output.featureValue(for: "r3o")?.multiArrayValue
        r4 = output.featureValue(for: "r4o")?.multiArrayValue

        // Extract alpha matte — output "pha" is a grayscale image
        if let phaBuffer = output.featureValue(for: "pha")?.imageBufferValue {
            return CIImage(cvPixelBuffer: phaBuffer)
        }
        return nil
    }

    func reset() {
        r1 = nil; r2 = nil; r3 = nil; r4 = nil
    }
}

// MARK: - MLFeatureProvider for model input

private class RVMInputProvider: MLFeatureProvider {
    let src: CVPixelBuffer
    let r1: MLMultiArray?
    let r2: MLMultiArray?
    let r3: MLMultiArray?
    let r4: MLMultiArray?

    var featureNames: Set<String> {
        var names: Set<String> = ["src"]
        if r1 != nil { names.insert("r1i") }
        if r2 != nil { names.insert("r2i") }
        if r3 != nil { names.insert("r3i") }
        if r4 != nil { names.insert("r4i") }
        return names
    }

    init(src: CVPixelBuffer, r1: MLMultiArray?, r2: MLMultiArray?, r3: MLMultiArray?, r4: MLMultiArray?) {
        self.src = src
        self.r1 = r1
        self.r2 = r2
        self.r3 = r3
        self.r4 = r4
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "src":
            return MLFeatureValue(pixelBuffer: src)
        case "r1i":
            return r1.map { MLFeatureValue(multiArray: $0) }
        case "r2i":
            return r2.map { MLFeatureValue(multiArray: $0) }
        case "r3i":
            return r3.map { MLFeatureValue(multiArray: $0) }
        case "r4i":
            return r4.map { MLFeatureValue(multiArray: $0) }
        default:
            return nil
        }
    }
}
