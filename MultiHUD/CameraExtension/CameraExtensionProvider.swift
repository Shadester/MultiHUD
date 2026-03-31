//
//  CameraExtensionProvider.swift
//  CameraExtension
//

import Foundation
import CoreMediaIO
import AVFoundation
import CoreImage
import CoreML
import Metal
import SwiftUI
import CoreGraphics
import IOKit.audio
import AppKit
import Vision
import os

let kFrameRate: Int = 30

private let kAppGroup = "HGS3GTCF73.net.fakeapps.MultiHUD"

private func sharedContainerURL(_ name: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup)?
        .appendingPathComponent(name)
}

private let logger = Logger(subsystem: "net.fakeapps.MultiHUD.CameraExtension", category: "camera")

// Stable UUIDs so the virtual camera keeps the same identity across launches
private let kDeviceUUID = UUID(uuidString: "17C9D6E2-4CA4-4CF1-A52C-C147F20C0086")!
private let kStreamUUID = UUID(uuidString: "40CF8ACC-893B-4EBD-AA86-1B4D26EEAF62")!

private let kDefaultWidth  = 1280
private let kDefaultHeight = 720

private enum WidgetDisplayItem {
    case weather(tempC: String, tempF: String, symbol: String)
    case weatherRaw(String)
    case clock(time: String, tz: String)
    case countup(String)
    case countdown(String)
}

// MARK: - Device Source

class CameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var _streamSource: CameraExtensionStreamSource!

    private let sessionQueue      = DispatchQueue(label: "com.multihud.session")
    private let videoOutputQueue  = DispatchQueue(label: "com.multihud.videoOutput")
    private let streamingQueue    = DispatchQueue(label: "com.multihud.streaming")
    // Serial queue — only one segmentation runs at a time
    private let segmentationQueue = DispatchQueue(label: "com.multihud.segmentation", qos: .userInitiated)

    private var captureSession: AVCaptureSession?
    private var streamTimer: DispatchSourceTimer?

    private let frameLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?

    // Async segmentation result — written from segmentationQueue, read from streamingQueue
    private let maskLock = NSLock()
    private var latestMaskCI: CIImage?

    // Single shared CIContext: Metal command queue + no caching (WWDC 2020 best practice for video).
    // CIContext is thread-safe — shared between streamingQueue and segmentationQueue.
    private let ciContext: CIContext = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return CIContext() }
        return CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    }()

    // RVM matting (CoreML) — nil means Vision fallback
    private var rvmMatting: RVMMatting?
    private var guidedFilter: GuidedFilter?
    private var useRVM: Bool { rvmMatting != nil }
    // Reusable mask bake buffer — avoids per-frame allocation
    private var maskBakeBuffer: CVPixelBuffer?

    // Cached CIFilter instances — creating CIFilter(name:) per frame is expensive.
    private let blendWithMaskFilter: CIFilter = CIFilter(name: "CIBlendWithMask")!
    private let dissolveFilter:      CIFilter = CIFilter(name: "CIDissolveTransition")!

    // Overlay text updated by WeatherService
    var overlayText: String = "…"

    // Virtual background
    private var backgroundCI: CIImage?
    private var backgroundFileMtime: Date?

    // Segmentation request — reused, only accessed from segmentationQueue
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return req
    }()

    // Frame counters
    private var segFrameCounter = 0          // throttle segmentation to every 3rd frame
    private var segmentationInFlight = false // prevent queue backlog
    private var frameCount = 0
    private var lastFrameLogTime = CFAbsoluteTimeGetCurrent()

    private var currentSettings = ExtensionSettings()
    private var settingsNotifyToken: Int32 = NOTIFY_TOKEN_INVALID

    // Clock formatter (re-used to avoid allocation each frame)
    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // Output resolution — switches dynamically via dual CMIOExtensionStreamFormat
    private var _videoDesc720:  CMFormatDescription!
    private var _videoDesc1080: CMFormatDescription!
    private var activeResolutionIndex: Int = 0   // 0 = 720p, 1 = 1080p

    private var outputWidth:  Int { activeResolutionIndex == 1 ? 1920 : kDefaultWidth }
    private var outputHeight: Int { activeResolutionIndex == 1 ? 1080 : kDefaultHeight }
    private var activeVideoDescription: CMFormatDescription {
        activeResolutionIndex == 1 ? _videoDesc1080 : _videoDesc720
    }

    // Pixel buffer pool — avoids per-frame allocation; nil'd when resolution changes
    private var outputBufferPool: CVPixelBufferPool?

    private static func readInitialResolutionIndex() -> Int {
        guard let url  = sharedContainerURL("settings.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["resolution"] as? String == "1080p" else {
            return 0
        }
        return 1
    }

    init(localizedName: String) {
        super.init()

        activeResolutionIndex = Self.readInitialResolutionIndex()

        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: kDeviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(kDefaultWidth), height: Int32(kDefaultHeight),
            extensions: nil,
            formatDescriptionOut: &_videoDesc720
        )
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: 1920, height: 1080,
            extensions: nil,
            formatDescriptionOut: &_videoDesc1080
        )

        let fmt720 = CMIOExtensionStreamFormat(
            formatDescription: _videoDesc720,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil
        )
        let fmt1080 = CMIOExtensionStreamFormat(
            formatDescription: _videoDesc1080,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil
        )

        _streamSource = CameraExtensionStreamSource(
            localizedName: "MultiHUD Video",
            streamID: kStreamUUID,
            formats: [fmt720, fmt1080],
            device: device
        )
        _streamSource.activeFormatIndex = activeResolutionIndex

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

    // Called from CameraExtensionStreamSource when AVFoundation sets a new activeFormatIndex
    // (e.g. at connect time when it picks the highest-resolution format).
    func applyResolutionIndex(_ index: Int) {
        streamingQueue.async { [weak self] in
            guard let self, index != self.activeResolutionIndex else { return }
            self.activeResolutionIndex = index
            self.outputBufferPool = nil
            self.latestMaskCI = nil
            self.backgroundCI = nil
            self.maskBakeBuffer = nil
            logger.log("applyResolutionIndex: \(index) (\(index == 1 ? "1080p" : "720p", privacy: .public))")
        }
    }

    // MARK: - Streaming lifecycle

    func startStreaming() {
        guard streamTimer == nil else { return }
        logger.log("startStreaming [rvm+guided-filter build]")

        currentSettings = ExtensionSettings.load()

        // Initialize RVM matting (falls back to Vision if model not found)
        let resolution = currentSettings.resolution
        rvmMatting = RVMMatting(resolution: resolution)
        guidedFilter = GuidedFilter()
        if rvmMatting != nil {
            logger.log("Using RVM matting (CoreML)")
        } else {
            logger.log("RVM unavailable, falling back to Vision segmentation")
        }
        if guidedFilter != nil {
            logger.log("Guided filter enabled")
        }

        notify_register_dispatch(
            "net.fakeapps.MultiHUD.settingsChanged",
            &settingsNotifyToken,
            streamingQueue
        ) { [weak self] _ in
            guard let self else { return }
            let oldResolution = self.currentSettings.resolution
            let oldCameraId   = self.currentSettings.cameraId
            self.currentSettings = ExtensionSettings.load()
            let oldIndex = oldResolution == "1080p" ? 1 : 0
            let newIndex = self.currentSettings.resolution == "1080p" ? 1 : 0
            if newIndex != oldIndex {
                self.activeResolutionIndex = newIndex
                self.outputBufferPool = nil
                self.latestMaskCI = nil
                self.backgroundCI = nil
                self.maskBakeBuffer = nil
                _ = self.rvmMatting?.switchResolution(self.currentSettings.resolution)
                logger.log("Resolution switching to \(newIndex == 1 ? "1080p" : "720p", privacy: .public)")
                self._streamSource.notifyActiveFormatChanged(newIndex)
            }
            if self.currentSettings.cameraId != oldCameraId {
                logger.log("Camera ID changed, hot-swapping input")
                self.sessionQueue.async { [weak self] in self?.switchCaptureDevice() }
            }
        }

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
        if settingsNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(settingsNotifyToken)
            settingsNotifyToken = NOTIFY_TOKEN_INVALID
        }
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

    // Hot-swap the physical camera input without stopping the session.
    private func switchCaptureDevice() {
        guard let session = captureSession else {
            startCaptureSession()
            return
        }
        guard let newCamera = selectCaptureDevice(),
              let newInput  = try? AVCaptureDeviceInput(device: newCamera) else {
            logger.error("switchCaptureDevice: could not create input for new camera")
            return
        }
        session.beginConfiguration()
        for input in session.inputs {
            if let di = input as? AVCaptureDeviceInput, di.device.hasMediaType(.video) {
                session.removeInput(di)
            }
        }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
        }
        session.commitConfiguration()
        logger.log("switchCaptureDevice: now using \(newCamera.localizedName, privacy: .public)")
    }

    private func buildCaptureSession() -> AVCaptureSession? {
        guard let camera = selectCaptureDevice() else {
            logger.error("No physical camera device found")
            return nil
        }
        logger.log("Using camera: \(camera.localizedName, privacy: .public)")

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            logger.error("Could not create input for \(camera.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

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
        logger.log("Capture session configured successfully")
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
        logger.log("DiscoverySession found \(discoverySession.devices.count) devices")
        for d in discoverySession.devices {
            logger.log("  device=\(d.localizedName, privacy: .public) type=\(d.deviceType.rawValue, privacy: .public)")
        }

        if let url  = sharedContainerURL("settings.json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id   = json["cameraId"] as? String, !id.isEmpty,
           let preferred = discoverySession.devices.first(where: { $0.uniqueID == id }) {
            logger.log("Using preferred camera: \(preferred.localizedName, privacy: .public)")
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
        let frameStart = CFAbsoluteTimeGetCurrent()

        frameLock.lock()
        let inputBuffer = latestPixelBuffer
        frameLock.unlock()

        // Kick off async segmentation on a dedicated serial queue.
        // Guard: skip if previous segmentation hasn't finished (prevents queue backlog → mask delay).
        segFrameCounter += 1
        let shouldSegment = !segmentationInFlight && (useRVM || (segFrameCounter % 3 == 0))
        if shouldSegment, let buf = inputBuffer {
            segmentationInFlight = true
            let quality = currentSettings.segQuality
            segmentationQueue.async { [weak self] in
                guard let self else { return }
                self.segmentationRequest.qualityLevel = quality
                self.runSegmentation(on: buf)
                self.streamingQueue.async { self.segmentationInFlight = false }
            }
        }

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
            formatDescription: activeVideoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard err == noErr, let sampleBuffer else { return }

        _streamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        )

        // Log frame timing every 30 frames to diagnose performance.
        frameCount += 1
        if frameCount % 30 == 0 {
            let elapsed = CFAbsoluteTimeGetCurrent() - frameStart
            let fps = 30.0 / (CFAbsoluteTimeGetCurrent() - lastFrameLogTime)
            logger.log("perf: frame=\(Int(elapsed * 1000))ms fps=\(String(format: "%.1f", fps), privacy: .public) bg=\(self.backgroundCI != nil, privacy: .public) mask=\(self.latestMaskCI != nil, privacy: .public)")
            lastFrameLogTime = CFAbsoluteTimeGetCurrent()
        }
    }

    // Runs on segmentationQueue — produces mask via RVM (preferred) or Vision (fallback).
    private func runSegmentation(on pixelBuffer: CVPixelBuffer) {
        let extent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        var maskCI: CIImage

        if let rvm = rvmMatting, let alpha = rvm.predict(pixelBuffer: pixelBuffer) {
            // RVM produces a true alpha matte at model resolution — scale to output.
            let sx = extent.width  / alpha.extent.width
            let sy = extent.height / alpha.extent.height
            maskCI = alpha.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .cropped(to: extent)
            // No temporal smoothing — RVM's ConvGRU provides built-in consistency.
        } else {
            // Vision fallback
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            guard (try? handler.perform([segmentationRequest])) != nil,
                  let maskBuffer = segmentationRequest.results?.first?.pixelBuffer else { return }
            maskCI = CIImage(cvPixelBuffer: maskBuffer)
            let sx = extent.width  / maskCI.extent.width
            let sy = extent.height / maskCI.extent.height
            maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .cropped(to: extent)

            // Temporal smoothing only for Vision (RVM has built-in temporal consistency).
            maskLock.lock()
            let prev = latestMaskCI
            maskLock.unlock()
            if let prev {
                dissolveFilter.setValue(prev,   forKey: kCIInputImageKey)
                dissolveFilter.setValue(maskCI, forKey: kCIInputTargetImageKey)
                dissolveFilter.setValue(0.6,    forKey: kCIInputTimeKey)
                maskCI = dissolveFilter.outputImage?.cropped(to: extent) ?? maskCI
            }
        }

        // Bake mask to pixel buffer to break lazy CIImage filter chain.
        // Reuse buffer across frames; reallocate only on resolution change.
        if maskBakeBuffer == nil
            || CVPixelBufferGetWidth(maskBakeBuffer!) != outputWidth
            || CVPixelBufferGetHeight(maskBakeBuffer!) != outputHeight {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey:  outputWidth,
                kCVPixelBufferHeightKey: outputHeight,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, outputWidth, outputHeight,
                                kCVPixelFormatType_OneComponent8, attrs as CFDictionary, &maskBakeBuffer)
        }
        if let bakeBuffer = maskBakeBuffer {
            do {
                let dest = CIRenderDestination(pixelBuffer: bakeBuffer)
                try ciContext.startTask(toRender: maskCI.cropped(to: extent), to: dest).waitUntilCompleted()
                maskCI = CIImage(cvPixelBuffer: bakeBuffer)
            } catch {
                logger.log("mask bake failed: \(error.localizedDescription, privacy: .public)")
                // Fall through with unbaked maskCI — still usable, just not materialized
            }
        }

        maskLock.lock()
        latestMaskCI = maskCI
        maskLock.unlock()
    }

    private func makeOutputPixelBuffer() -> CVPixelBuffer? {
        if outputBufferPool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: outputWidth,
                kCVPixelBufferHeightKey: outputHeight,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            outputBufferPool = pool
        }
        guard let pool = outputBufferPool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    // MARK: - Rendering

    private func render(input: CVPixelBuffer?, into output: CVPixelBuffer) {
        let extent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let settings = currentSettings

        loadBackgroundIfNeeded()

        // Scale webcam frame to output size, or use a dark fallback.
        var webcamLayer: CIImage
        if let input {
            let img = CIImage(cvPixelBuffer: input)
            let sx = CGFloat(outputWidth)  / img.extent.width
            let sy = CGFloat(outputHeight) / img.extent.height
            let scale = max(sx, sy)
            let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let ox = (CGFloat(outputWidth)  - scaled.extent.width)  / 2
            let oy = (CGFloat(outputHeight) - scaled.extent.height) / 2
            webcamLayer = scaled
                .transformed(by: CGAffineTransform(translationX: ox, y: oy))
                .cropped(to: extent)
        } else {
            webcamLayer = CIImage(color: CIColor(red: 0.08, green: 0.11, blue: 0.14))
                .cropped(to: extent)
        }


        // Grab the latest async segmentation mask (may be nil for first few frames).
        maskLock.lock()
        let rawMask = latestMaskCI
        maskLock.unlock()

        // Apply guided filter using the current webcam frame as guide.
        // Running at render time (not in runSegmentation) ensures edges always align to the
        // frame being displayed, not the stale frame that was fed to RVM inference.
        let refinedMask = guidedFilter.flatMap { gf in
            rawMask.map { gf.apply(guide: webcamLayer, mask: $0) }
        } ?? rawMask
        // Optional mask sharpening: gamma > 1 pushes uncertain mid-alpha boundary pixels toward
        // transparent while leaving high-confidence person pixels (≈1.0) nearly unchanged.
        // Reduces real-background bleed-through at person edges.
        // power=1 (default) = no effect; power=2: alpha 0.9→0.81, 0.5→0.25, 0.2→0.04
        let sharpening = settings.maskSharpening
        let mask: CIImage? = (sharpening > 1.0)
            ? refinedMask.map { $0.applyingFilter("CIGammaAdjust", parameters: ["inputPower": sharpening]) }
            : refinedMask

        // Apply virtual background or blur via person segmentation mask.
        let baseLayer: CIImage
        if let customBg = backgroundCI {
            // Custom background image: pre-scaled at load time, use directly each frame.
            if input != nil, let mask {
                baseLayer = compositeWithMask(person: webcamLayer, background: customBg, mask: mask)
            } else {
                baseLayer = customBg
            }
        } else if settings.blurBackground, input != nil, let mask {
            // Gaussian blur of the webcam layer as background.
            let blurred = webcamLayer.applyingGaussianBlur(sigma: 15).cropped(to: extent)
            baseLayer = compositeWithMask(person: webcamLayer, background: blurred, mask: mask)
        } else {
            baseLayer = webcamLayer
        }

        // Composite overlay pills on top (one pill per position group).
        // Compute Date once so the clock widget and timer math share the same timestamp.
        let date = Date()
        let now  = date.timeIntervalSince1970
        let enabledWidgets = settings.widgets.filter { $0.enabled }
        let groups = Dictionary(grouping: enabledWidgets, by: \.position)
        var composite = baseLayer
        for (position, widgets) in groups {
            let items = widgets.compactMap { widgetDisplayItem($0, now: now, date: date) }
            guard !items.isEmpty else { continue }
            if let pillCI = makePillCIImage(items, position: position, opacity: settings.opacity,
                                            canvasSize: CGSize(width: outputWidth, height: outputHeight)) {
                composite = pillCI.composited(over: composite)
            }
        }

        // Use CIRenderDestination for async GPU pipelining (WWDC 2020).
        let dest = CIRenderDestination(pixelBuffer: output)
        try? ciContext.startTask(toRender: composite, to: dest)
    }

    private func positioned(_ image: CIImage, in extent: CGRect) -> CIImage {
        let sx = extent.width  / image.extent.width
        let sy = extent.height / image.extent.height
        let s  = max(sx, sy)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let ox = (extent.width  - scaled.extent.width)  / 2
        let oy = (extent.height - scaled.extent.height) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            .cropped(to: extent)
    }

    private func compositeWithMask(person: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        blendWithMaskFilter.setValue(person,     forKey: kCIInputImageKey)
        blendWithMaskFilter.setValue(background, forKey: kCIInputBackgroundImageKey)
        blendWithMaskFilter.setValue(mask,       forKey: kCIInputMaskImageKey)
        return blendWithMaskFilter.outputImage ?? person
    }

    private func loadBackgroundIfNeeded() {
        guard let url = sharedContainerURL("background.jpg") else {
            backgroundCI = nil
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        guard mtime != backgroundFileMtime || backgroundCI == nil else { return }
        backgroundFileMtime = mtime
        guard mtime != nil, let raw = CIImage(contentsOf: url) else {
            backgroundCI = nil
            return
        }
        // Scale to output dimensions, then bake into a pixel buffer so every frame
        // reads pre-decoded pixels instead of re-decoding the JPEG via the lazy filter chain.
        let extent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let positionedRaw = positioned(raw, in: extent)
        var baked: CVPixelBuffer?
        let attrs2: [CFString: Any] = [
            kCVPixelBufferWidthKey:  outputWidth,
            kCVPixelBufferHeightKey: outputHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, outputWidth, outputHeight,
                            kCVPixelFormatType_32BGRA, attrs2 as CFDictionary, &baked)
        if let baked {
            ciContext.render(positionedRaw, to: baked, bounds: extent,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            backgroundCI = CIImage(cvPixelBuffer: baked)
        } else {
            backgroundCI = positionedRaw
        }
    }

    private func widgetDisplayItem(_ w: WidgetConfig, now: Double, date: Date) -> WidgetDisplayItem? {
        switch w.type {
        case .weather:
            let parts = overlayText.split(separator: "|", maxSplits: 2)
            if parts.count == 3 {
                return .weather(tempC: String(parts[0]), tempF: String(parts[1]), symbol: String(parts[2]))
            }
            return .weatherRaw(overlayText)
        case .clock:
            let time = clockFormatter.string(from: date)
            let tz = TimeZone.current.abbreviation() ?? ""
            return .clock(time: time, tz: tz)
        case .countup:
            guard w.startedAt > 0 else { return nil }
            return .countup(formatDuration(now - w.startedAt))
        case .countdown:
            guard w.endsAt > 0 else { return nil }
            return .countdown(formatDuration(max(0, w.endsAt - now)))
        }
    }

    private func makePillCIImage(
        _ items: [WidgetDisplayItem],
        position: OverlayPosition,
        opacity: Double,
        canvasSize: CGSize
    ) -> CIImage? {
        let renderOverlay = {
            MainActor.assumeIsolated {
                let view = OverlayPillView(items: items, opacity: opacity)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                renderer.proposedSize = ProposedViewSize(width: nil, height: nil)
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
        let inset: CGFloat = 28
        let iw = image.extent.width
        let ih = image.extent.height

        let x: CGFloat
        let y: CGFloat
        switch position {
        case .bottomLeft:    x = inset;                               y = inset
        case .bottomRight:   x = canvasSize.width  - iw - inset;     y = inset
        case .topLeft:       x = inset;                               y = canvasSize.height - ih - inset
        case .topRight:      x = canvasSize.width  - iw - inset;     y = canvasSize.height - ih - inset
        case .bottomCenter:  x = (canvasSize.width - iw) / 2;        y = inset
        }

        return image.transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}

// MARK: - Overlay SwiftUI View

private struct OverlayPillView: View {
    let items: [WidgetDisplayItem]
    let opacity: Double

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { pillDivider }
                itemView(for: item)
            }
        }
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .opacity(opacity)
    }

    @ViewBuilder
    private func itemView(for item: WidgetDisplayItem) -> some View {
        switch item {
        case .weather(let tempC, let tempF, let symbol):
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                Text("\(tempC)°C / \(tempF)°F")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
        case .weatherRaw(let text):
            Text(text)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
        case .clock(let time, let tz):
            Text("\(time) \(tz)")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
        case .countup(let elapsed):
            HStack(spacing: 4) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 14, weight: .medium))
                Text(elapsed)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
            }
        case .countdown(let remaining):
            HStack(spacing: 4) {
                Image(systemName: "hourglass.tophalf.filled")
                    .font(.system(size: 14, weight: .medium))
                Text(remaining)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
            }
        }
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.5))
            .frame(width: 1.5, height: 18)
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
    private let _streamFormats: [CMIOExtensionStreamFormat]

    init(localizedName: String, streamID: UUID, formats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormats = formats
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { _streamFormats }
    var activeFormatIndex: Int = 0

    func notifyActiveFormatChanged(_ index: Int) {
        activeFormatIndex = index
        logger.log("notifyActiveFormatChanged: index=\(index)")
        stream.notifyPropertiesChanged([
            .streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: index as NSNumber)
        ])
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex {
            activeFormatIndex = idx
            (device.source as? CameraExtensionDeviceSource)?.applyResolutionIndex(idx)
        }
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
