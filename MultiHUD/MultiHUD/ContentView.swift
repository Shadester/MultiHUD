//
//  ContentView.swift
//  MultiHUD
//

import SwiftUI
import AppKit
import AVFoundation
import CoreLocation
import UniformTypeIdentifiers

private let kAppGroup = "HGS3GTCF73.net.fakeapps.MultiHUD"

private func sharedURL(_ name: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup)?
        .appendingPathComponent(name)
}

// MARK: - Camera preview (NSViewRepresentable)

private struct CapturePreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}

// MARK: - ContentView

struct ContentView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ExtensionManager.self) private var ext

    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var cameras: [AVCaptureDevice] = []
    @State private var hasBackground = false
    @State private var showBackgroundPicker = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var previewSession: AVCaptureSession?

    // Created once at the type level — DateFormatter is expensive to allocate.
    private static let clockPreviewFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var clockPreview: String {
        let tz = TimeZone.current.abbreviation() ?? ""
        return "\(Self.clockPreviewFormatter.string(from: Date())) \(tz)"
    }

    private var locationStatus: CLAuthorizationStatus {
        HostWeatherService.shared.locationStatus
    }

    private var locationGranted: Bool {
        switch locationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(spacing: 20) {
                Text("MultiHUD")
                    .font(.largeTitle.bold())

                // Extension status
                HStack(spacing: 8) {
                    Circle()
                        .fill(ext.state.isActive ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                    Text(ext.state.label)
                        .foregroundStyle(.secondary)
                }

                // Action buttons
                if ext.state.isActive {
                    Button("Uninstall Camera Extension", role: .destructive) {
                        ext.uninstall()
                        stopPreview()
                    }
                    .disabled(ext.state.isBusy)
                } else if ext.state.needsApproval {
                    Button("Open System Settings → Camera Extensions") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .buttonStyle(.borderedProminent)
                } else if ext.state.needsReboot {
                    Label("Reboot required to finish installation", systemImage: "restart.circle")
                        .foregroundStyle(.orange)
                } else {
                    Button("Install Camera Extension") { ext.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(ext.state.isBusy)
                }

                // Live preview
                if ext.state.isActive {
                    Group {
                        if let session = previewSession {
                            CapturePreviewView(session: session)
                                .frame(width: 320, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(0.7))
                                .frame(width: 320, height: 180)
                                .overlay {
                                    Text("Preview loading…")
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                }
                        }
                    }
                }

                Divider()

                // Camera permission
                HStack(spacing: 8) {
                    Circle()
                        .fill(cameraStatus == .authorized ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    switch cameraStatus {
                    case .authorized:
                        Text("Camera access granted").foregroundStyle(.secondary)
                    case .denied, .restricted:
                        Text("Camera access denied").foregroundStyle(.orange)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    default:
                        Text("Camera access required").foregroundStyle(.orange)
                        Button("Grant Access") { Task { await requestCameraAccess() } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }

                // Location permission
                HStack(spacing: 8) {
                    Circle()
                        .fill(locationGranted ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    switch locationStatus {
                    case .authorizedAlways, .authorizedWhenInUse:
                        Text("Location access granted").foregroundStyle(.secondary)
                    case .denied, .restricted:
                        Text("Location access denied").foregroundStyle(.orange)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Location")!)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    default:
                        Text("Location access required for weather").foregroundStyle(.orange)
                        Button("Grant Access") { HostWeatherService.shared.requestLocationAccess() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }

                Divider()

                // Camera source picker
                if cameraStatus == .authorized, !cameras.isEmpty {
                    Picker("Camera source", selection: $settings.cameraId) {
                        Text("Auto").tag("")
                        ForEach(cameras, id: \.uniqueID) { cam in
                            Text(cam.localizedName).tag(cam.uniqueID)
                        }
                    }
                    .onChange(of: settings.cameraId) { _, _ in settings.save() }
                }

                // Virtual background / blur
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if hasBackground {
                            Text("Virtual background set").foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") { clearBackground() }.controlSize(.small)
                        } else {
                            Button("Set virtual background…") { showBackgroundPicker = true }
                        }
                    }
                    Toggle("Blur background (no image needed)", isOn: $settings.blurBackground)
                        .onChange(of: settings.blurBackground) { _, _ in settings.save() }
                        .disabled(hasBackground)
                        .foregroundStyle(hasBackground ? .tertiary : .primary)
                }
                .fileImporter(
                    isPresented: $showBackgroundPicker,
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: false
                ) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    importBackground(from: url)
                }

                Divider()

                // Overlay settings
                DisclosureGroup("Overlay Settings", isExpanded: $showSettings) {
                    VStack(alignment: .leading, spacing: 16) {

                        Text("Widgets").font(.headline)

                        widgetRow(label: "Weather", enabled: $settings.weatherEnabled,
                                  position: $settings.weatherPosition, preview: "Shows temperature")

                        widgetRow(label: "Clock", enabled: $settings.clockEnabled,
                                  position: $settings.clockPosition, preview: clockPreview)

                        // Meeting countup
                        VStack(alignment: .leading, spacing: 6) {
                            widgetRow(label: "Meeting timer", enabled: $settings.countupEnabled,
                                      position: $settings.countupPosition, preview: nil)
                            if settings.countupEnabled && settings.countupStartedAt == 0 {
                                Text("Press Start to show in overlay")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Button(settings.countupStartedAt > 0 ? "Restart" : "Start") {
                                    settings.startCountup()
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(!settings.countupEnabled)
                                Button("Reset") { settings.resetCountup() }
                                    .controlSize(.small)
                                    .disabled(settings.countupStartedAt == 0)
                            }
                        }

                        // Countdown
                        VStack(alignment: .leading, spacing: 6) {
                            widgetRow(label: "Countdown", enabled: $settings.countdownEnabled,
                                      position: $settings.countdownPosition, preview: nil)
                            if settings.countdownEnabled && settings.countdownEndsAt == 0 {
                                Text("Press Start to show in overlay")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            DatePicker("End time", selection: $settings.countdownEndTime,
                                       displayedComponents: .hourAndMinute)
                                .onChange(of: settings.countdownEndTime) { _, _ in settings.save() }
                            HStack(spacing: 8) {
                                Button(settings.countdownEndsAt > 0 ? "Restart" : "Start") {
                                    settings.startCountdown()
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(!settings.countdownEnabled)
                                Button("Reset") { settings.resetCountdown() }
                                    .controlSize(.small)
                                    .disabled(settings.countdownEndsAt == 0)
                            }
                        }

                        Divider()

                        HStack {
                            Text("Opacity")
                            Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.05)
                                .onChange(of: settings.opacity) { _, _ in settings.save() }
                            Text("\(Int(settings.opacity * 100))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }

                        Picker("Output resolution", selection: $settings.resolution) {
                            Text("720p — 1280×720 (default)").tag("720p")
                            Text("1080p — 1920×1080").tag("1080p")
                        }
                        .onChange(of: settings.resolution) { _, _ in settings.save() }
                        Text("Resolution takes effect when the next video call starts.")
                            .font(.caption).foregroundStyle(.secondary)

                        Picker("Segmentation quality", selection: $settings.segQuality) {
                            Text("Fast (recommended)").tag("fast")
                            Text("Balanced").tag("balanced")
                            Text("Accurate").tag("accurate")
                        }
                        .onChange(of: settings.segQuality) { _, _ in settings.save() }

                    }
                    .padding(.top, 8)
                }

                Divider()

                Text("After installing, select **MultiHUD** as your camera in Zoom, Meet, or any video app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(32)
        }
        .frame(minWidth: 400, minHeight: 360)
        .task {
            cameras = loadCameras()
            hasBackground = sharedURL("background.jpg").map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            if ext.state.isActive { startPreview() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        .onChange(of: ext.state.isActive) { _, isActive in
            if isActive { startPreview() } else { stopPreview() }
        }
    }

    // MARK: - Widget row

    @ViewBuilder
    private func widgetRow(label: String, enabled: Binding<Bool>, position: Binding<String>, preview: String?) -> some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: enabled)
                .onChange(of: enabled.wrappedValue) { _, _ in settings.save() }
                .frame(minWidth: 100, alignment: .leading)
            Spacer()
            if let preview {
                Text(preview).font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: position) {
                Text("↙").tag("bottomLeft")
                Text("↓").tag("bottomCenter")
                Text("↘").tag("bottomRight")
                Text("↖").tag("topLeft")
                Text("↗").tag("topRight")
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: position.wrappedValue) { _, _ in settings.save() }
        }
    }

    // MARK: - Camera access

    private func requestCameraAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = granted ? .authorized : .denied
        if granted { cameras = loadCameras() }
    }

    private func loadCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices.filter { $0.localizedName != "MultiHUD" }
    }

    // MARK: - Background

    private func importBackground(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let dest = sharedURL("background.jpg"),
              let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        try? data.write(to: dest)
        hasBackground = true
    }

    private func clearBackground() {
        if let url = sharedURL("background.jpg") {
            try? FileManager.default.removeItem(at: url)
        }
        hasBackground = false
    }

    // MARK: - Preview

    private func startPreview() {
        guard previewSession == nil else { return }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices
        guard let virtualCam = devices.first(where: { $0.localizedName == "MultiHUD" }),
              let input = try? AVCaptureDeviceInput(device: virtualCam) else { return }
        let session = AVCaptureSession()
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        previewSession = session
        Task.detached(priority: .userInitiated) { session.startRunning() }
    }

    private func stopPreview() {
        previewSession?.stopRunning()
        previewSession = nil
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(ExtensionManager())
}
