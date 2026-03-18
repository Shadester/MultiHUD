//
//  CameraExtensionProvider.swift
//  CameraExtension
//

import Foundation
import CoreMediaIO
import AVFoundation
import CoreImage
import SwiftUI
import CoreGraphics
import IOKit.audio
import AppKit
import Vision
import os

let kFrameRate: Int = 30

private let sharedCameraIDFileURL: URL? =
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "HGS3GTCF73.net.fakeapps.MultiHUD")?
        .appendingPathComponent("camera-id.txt")

private let sharedBackgroundFileURL: URL? =
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "HGS3GTCF73.net.fakeapps.MultiHUD")?
        .appendingPathComponent("background.jpg")

private let logger = Logger(subsystem: "net.fakeapps.MultiHUD.CameraExtension", category: "camera")

// Stable UUIDs so the virtual camera keeps the same identity across launches
private let kDeviceUUID = UUID(uuidString: "17C9D6E2-4CA4-4CF1-A52C-C147F20C0086")!
private let kStreamUUID = UUID(uuidString: "40CF8ACC-893B-4EBD-AA86-1B4D26EEAF62")!

private let kWidth  = 1280
private let kHeight = 720

// MARK: - Device Source

class CameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var _streamSource: CameraExtensionStreamSource!
    private var _videoDescription: CMFormatDescription!

    private let sessionQueue    = DispatchQueue(label: "com.multihud.session")
    private let videoOutputQueue = DispatchQueue(label: "com.multihud.videoOutput")
    private let streamingQueue  = DispatchQueue(label: "com.multihud.streaming")

    private var captureSession: AVCaptureSession?
    private var streamTimer: DispatchSourceTimer?

    private let frameLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?

    private let ciContext = CIContext()

    // Overlay text updated by WeatherService
    var overlayText: String = "…"

    // Virtual background
    private var backgroundCI: CIImage?
    private var backgroundFileMtime: Date?

    init(localizedName: String) {
        super.init()
        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: kDeviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        let dims = CMVideoDimensions(width: Int32(kWidth), height: Int32(kHeight))
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dims.width,
            height: dims.height,
            extensions: nil,
            formatDescriptionOut: &_videoDescription
        )

        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil
        )

        _streamSource = CameraExtensionStreamSource(
            localizedName: "MultiHUD Video",
            streamID: kStreamUUID,
            streamFormat: videoStreamFormat,
            device: device
        )
        do {
            try device.addStream(_streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }

    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { props.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { props.model = "MultiHUD Camera" }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Streaming lifecycle

    func startStreaming() {
        guard streamTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: streamingQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        streamTimer = timer
        timer.resume()

        sessionQueue.async { [weak self] in self?.startCaptureSession() }

        if let url = URL(string: "multihud://wake") {
            NSWorkspace.shared.open(url)
        }
    }

    func stopStreaming() {
        streamTimer?.cancel()
        streamTimer = nil
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
        }
    }

    // MARK: - Capture session

    private func startCaptureSession() {
        if captureSession == nil {
            captureSession = buildCaptureSession()
        }
        if let session = captureSession, !session.isRunning {
            session.startRunning()
        }
    }

    private func buildCaptureSession() -> AVCaptureSession? {
        guard let camera = selectCaptureDevice() else {
            logger.error("No physical camera device found")
            return nil
        }
        logger.info("Using camera: \(camera.localizedName, privacy: .public)")

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            logger.error("Could not create input for \(camera.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard session.canAddInput(input) else {
            logger.error("Cannot add input to session")
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoOutputQueue)

        guard session.canAddOutput(output) else {
            logger.error("Could not add video output")
            session.commitConfiguration()
            return nil
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        session.commitConfiguration()
        logger.info("Capture session configured successfully")
        return session
    }

    private func selectCaptureDevice() -> AVCaptureDevice? {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.insert(.continuityCamera, at: 1)
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        logger.info("DiscoverySession found \(discoverySession.devices.count) devices")
        for d in discoverySession.devices {
            logger.info("  device=\(d.localizedName, privacy: .public) type=\(d.deviceType.rawValue, privacy: .public)")
        }

        if let url = sharedCameraIDFileURL,
           let savedID = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !savedID.isEmpty,
           let preferred = discoverySession.devices.first(where: { $0.uniqueID == savedID }) {
            logger.info("Using preferred camera: \(preferred.localizedName, privacy: .public)")
            return preferred
        }

        let physicalTypes: Set<AVCaptureDevice.DeviceType> = {
            if #available(macOS 14.0, *) {
                return [.builtInWideAngleCamera, .continuityCamera]
            } else {
                return [.builtInWideAngleCamera]
            }
        }()

        let physical = discoverySession.devices.filter { physicalTypes.contains($0.deviceType) }
        if let cam = physical.first(where: { $0.position == .front }) ?? physical.first {
            return cam
        }

        let virtualNames = ["MultiHUD", "OBS", "Cascable", "Trypophobia", "Virtual", "NDI"]
        let fallback = discoverySession.devices.filter { device in
            !virtualNames.contains(where: { device.localizedName.localizedCaseInsensitiveContains($0) })
        }
        return fallback.first(where: { $0.position == .front }) ?? fallback.first
    }

    // MARK: - Frame emission

    private func emitFrame() {
        frameLock.lock()
        let inputBuffer = latestPixelBuffer
        frameLock.unlock()

        guard let outBuffer = makeOutputPixelBuffer() else { return }
        render(input: inputBuffer, into: outBuffer)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: _videoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard err == noErr, let sampleBuffer else { return }

        _streamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        )
    }

    private func makeOutputPixelBuffer() -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: kWidth,
            kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    // MARK: - Rendering

    private func render(input: CVPixelBuffer?, into output: CVPixelBuffer) {
        let extent = CGRect(x: 0, y: 0, width: kWidth, height: kHeight)

        loadBackgroundIfNeeded()

        // Scale webcam frame to output size, or use a dark fallback.
        let webcamLayer: CIImage
        if let input {
            let img = CIImage(cvPixelBuffer: input)
            let sx = CGFloat(kWidth)  / img.extent.width
            let sy = CGFloat(kHeight) / img.extent.height
            let scale = max(sx, sy)
            let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let ox = (CGFloat(kWidth)  - scaled.extent.width)  / 2
            let oy = (CGFloat(kHeight) - scaled.extent.height) / 2
            webcamLayer = scaled
                .transformed(by: CGAffineTransform(translationX: ox, y: oy))
                .cropped(to: extent)
        } else {
            webcamLayer = CIImage(color: CIColor(red: 0.08, green: 0.11, blue: 0.14))
                .cropped(to: extent)
        }

        // Apply virtual background via person segmentation (if configured).
        let baseLayer: CIImage
        if let customBg = backgroundCI, let input {
            baseLayer = applyVirtualBackground(
                webcam: webcamLayer, webcamBuffer: input, background: customBg, extent: extent
            )
        } else {
            baseLayer = webcamLayer
        }

        // Composite weather pill on top — always visible, even if the video app
        // does its own background replacement on our output stream.
        let composite: CIImage
        if let overlayCI = makeOverlayCIImage(canvasSize: CGSize(width: kWidth, height: kHeight)) {
            composite = overlayCI.composited(over: baseLayer)
        } else {
            composite = baseLayer
        }

        ciContext.render(composite, to: output)
    }

    private func loadBackgroundIfNeeded() {
        guard let url = sharedBackgroundFileURL else {
            backgroundCI = nil
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        guard mtime != backgroundFileMtime else { return }
        backgroundFileMtime = mtime
        backgroundCI = mtime != nil ? CIImage(contentsOf: url) : nil
    }

    private func applyVirtualBackground(
        webcam: CIImage,
        webcamBuffer: CVPixelBuffer,
        background: CIImage,
        extent: CGRect
    ) -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cvPixelBuffer: webcamBuffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = request.results?.first?.pixelBuffer else { return webcam }

        // Scale mask to match output frame.
        var maskCI = CIImage(cvPixelBuffer: maskBuffer)
        let maskScaleX = extent.width  / maskCI.extent.width
        let maskScaleY = extent.height / maskCI.extent.height
        maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: maskScaleX, y: maskScaleY))

        // Scale and center-crop custom background to fill the output frame.
        let bgScaleX = extent.width  / background.extent.width
        let bgScaleY = extent.height / background.extent.height
        let bgScale  = max(bgScaleX, bgScaleY)
        let scaledBg = background.transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
        let ox = (extent.width  - scaledBg.extent.width)  / 2
        let oy = (extent.height - scaledBg.extent.height) / 2
        let positionedBg = scaledBg
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            .cropped(to: extent)

        // CIBlendWithMask: white mask → inputImage (webcam/person), black → backgroundImage (custom bg).
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return webcam }
        blend.setValue(webcam,       forKey: kCIInputImageKey)
        blend.setValue(positionedBg, forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskCI,       forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? webcam
    }

    /// Renders the text pill as a SwiftUI view via ImageRenderer, returns a CIImage
    /// positioned at the bottom-left of the canvas (in CIImage's y-up coordinate space).
    private func makeOverlayCIImage(canvasSize: CGSize) -> CIImage? {
        let text = overlayText

        let renderOverlay = {
            MainActor.assumeIsolated {
                let view = OverlayPillView(text: text)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                return renderer.cgImage
            }
        }

        let cgImage: CGImage?
        if Thread.isMainThread {
            cgImage = renderOverlay()
        } else {
            cgImage = DispatchQueue.main.sync(execute: renderOverlay)
        }

        guard let cgImage else { return nil }

        let image = CIImage(cgImage: cgImage)
        // Place at bottom-left with 28pt inset (CIImage y-up: y=28 is near bottom).
        let inset: CGFloat = 28
        return image.transformed(by: CGAffineTransform(translationX: inset, y: inset))
    }
}

// MARK: - Overlay SwiftUI View

private struct OverlayPillView: View {
    let text: String

    // Parses "tempC|tempF|symbolName" or falls back to showing raw text
    private var parsed: (tempC: String, tempF: String, symbol: String)? {
        let parts = text.split(separator: "|", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    var body: some View {
        Group {
            if let p = parsed {
                HStack(spacing: 6) {
                    Image(systemName: p.symbol)
                        .font(.system(size: 16, weight: .medium))
                    Text("\(p.tempC)°C / \(p.tempF)°F")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
            } else {
                Text(text)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraExtensionDeviceSource: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        latestPixelBuffer = pixelBuffer
        frameLock.unlock()
    }
}

// MARK: - Stream Source

class CameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? CameraExtensionDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device.source as? CameraExtensionDeviceSource)?.stopStreaming()
    }
}

// MARK: - Provider Source

class CameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private(set) var deviceSource: CameraExtensionDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraExtensionDeviceSource(localizedName: "MultiHUD")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { props.manufacturer = "MultiHUD" }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
