//
//  ContentView.swift
//  MultiHUD
//

import SwiftUI
import AppKit
import AVFoundation
import Combine
import CoreLocation
import UniformTypeIdentifiers
import os.log

private let previewLogger = Logger(subsystem: "net.fakeapps.MultiHUD", category: "preview")

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

    var showPreview: Bool = true

    @Environment(AppSettings.self) private var settings
    @Environment(ExtensionManager.self) private var ext

    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var cameras: [AVCaptureDevice] = []
    @State private var hasBackground = false
    @State private var showBackgroundPicker = false
    @State private var activelyUsingRVM: Bool? = nil
    @State private var rvmFailureReason: String? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewSession: AVCaptureSession?

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
        VStack(spacing: 0) {
            if showPreview, ext.state.isActive {
                Group {
                    if let session = previewSession {
                        CapturePreviewView(session: session)
                    } else {
                        Color.black.opacity(0.85)
                            .overlay {
                                Text("Preview loading…")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            TabView {
                cameraTab
                    .tabItem { Label("Camera", systemImage: "camera.fill") }
                widgetsTab
                    .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
        .task {
            cameras = loadCameras()
            hasBackground = sharedURL("background.jpg").map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            readCamStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        .onChange(of: cameraStatus) { _, newStatus in
            // When the user grants camera access (via System Settings or in-app dialog),
            // trigger preview immediately rather than waiting for the 2-second safety net.
            if newStatus == .authorized, showPreview, ext.state.isActive, previewSession == nil {
                Task { await startPreviewWithRetry() }
            }
        }
        .task(id: ext.state.isActive) {
            guard showPreview else { return }
            if ext.state.isActive {
                readCamStatus()
                if ext.justInstalled {
                    // Fresh install: AVCaptureDevice.DiscoverySession won't see the newly
                    // registered virtual camera until the host app process is restarted.
                    // This is a documented macOS CMIOExtension limitation.
                    relaunchApp()
                } else {
                    await startPreviewWithRetry()
                }
            } else {
                stopPreview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { notif in
            guard showPreview,
                  let device = notif.object as? AVCaptureDevice,
                  device.localizedName == "MultiHUD" else { return }
            stopPreview()
            Task { await startPreviewWithRetry() }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // Safety net: if extension is active but preview never started, keep trying.
            guard showPreview, ext.state.isActive, previewSession == nil else { return }
            Task { await startPreviewWithRetry() }
        }
    }

    // MARK: - Camera tab

    private var cameraTab: some View {
        let s = Bindable(settings)
        return Form {
            Section("Extension") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ext.state.isActive ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(ext.state.label).foregroundStyle(.secondary)
                }

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
            }

            Section("Access") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(cameraStatus == .authorized ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    switch cameraStatus {
                    case .authorized:
                        Text("Camera access granted").foregroundStyle(.secondary)
                    case .denied, .restricted:
                        Text("Camera access denied").foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    default:
                        Text("Camera access required").foregroundStyle(.orange)
                        Spacer()
                        Button("Grant Access") { Task { await requestCameraAccess() } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(locationGranted ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    switch locationStatus {
                    case .authorizedAlways, .authorizedWhenInUse:
                        Text("Location access granted").foregroundStyle(.secondary)
                    case .denied, .restricted:
                        Text("Location access denied").foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Location")!)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    default:
                        Text("Location access required for weather").foregroundStyle(.orange)
                        Spacer()
                        Button("Grant Access") { HostWeatherService.shared.requestLocationAccess() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }

            Section("Source") {
                if cameraStatus == .authorized, !cameras.isEmpty {
                    Picker("Camera", selection: s.cameraId) {
                        Text("Auto").tag("")
                        ForEach(cameras, id: \.uniqueID) { cam in
                            Text(cam.localizedName).tag(cam.uniqueID)
                        }
                    }
                    .onChange(of: settings.cameraId) { _, _ in settings.save() }
                }

                if hasBackground {
                    HStack {
                        Text("Virtual background").foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { clearBackground() }.controlSize(.small)
                    }
                } else {
                    Button("Set virtual background…") { showBackgroundPicker = true }
                }

                Toggle("Blur background", isOn: s.blurBackground)
                    .onChange(of: settings.blurBackground) { _, _ in settings.save() }
                    .disabled(hasBackground)
            }

            Section("Video") {
                Picker("Resolution", selection: s.resolution) {
                    Text("720p — 1280×720 (default)").tag("720p")
                    Text("1080p — 1920×1080").tag("1080p")
                }
                .onChange(of: settings.resolution) { _, _ in settings.save() }

                Picker("Engine", selection: s.useRVM) {
                    Text("RVM").tag(true)
                    Text("Vision").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.useRVM) { _, _ in
                    settings.save()
                    // Allow extension time to apply the change and write camstatus.json
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { readCamStatus() }
                }

                if let active = activelyUsingRVM {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(active ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        if active {
                            Text("Using RVM matting").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Using Vision segmentation").foregroundStyle(.secondary)
                                if let reason = rvmFailureReason {
                                    Text(reason).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                if !settings.useRVM {
                    Picker("Quality", selection: s.segQuality) {
                        Text("Fast").tag("fast")
                        Text("Balanced (recommended)").tag("balanced")
                        Text("Accurate").tag("accurate")
                    }
                    .onChange(of: settings.segQuality) { _, _ in settings.save() }
                }

                Text("After installing, select **MultiHUD** as your camera in Zoom, Meet, or any video app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Section {
                    Text("MultiHUD v\(version)")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .font(.footnote)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showBackgroundPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importBackground(from: url)
        }
    }

    // MARK: - Widgets tab

    private var widgetsTab: some View {
        let s = Bindable(settings)
        return Form {
            Section("Overlay") {
                HStack {
                    Text("Opacity")
                    Slider(value: s.opacity, in: 0.1...1.0, step: 0.05)
                        .onChange(of: settings.opacity) { _, _ in settings.save() }
                    Text("\(Int(settings.opacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Section("Weather") {
                widgetRow(label: "Weather", enabled: s.weatherEnabled,
                          position: s.weatherPosition, preview: "Temperature")
            }

            Section("Clock") {
                widgetRow(label: "Clock", enabled: s.clockEnabled,
                          position: s.clockPosition, preview: clockPreview)
            }

            Section("Meeting Timer") {
                widgetRow(label: "Meeting timer", enabled: s.countupEnabled,
                          position: s.countupPosition, preview: nil)
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

            Section("Countdown") {
                widgetRow(label: "Countdown", enabled: s.countdownEnabled,
                          position: s.countdownPosition, preview: nil)
                DatePicker("End time", selection: s.countdownEndTime,
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
        }
        .formStyle(.grouped)
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
            PositionGridPicker(position: position)
                .onChange(of: position.wrappedValue) { _, _ in settings.save() }
        }
    }

    // MARK: - Camera access

    private func readCamStatus() {
        guard let url = sharedURL("camstatus.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        activelyUsingRVM = json["usingRVM"] as? Bool
        rvmFailureReason = json["rvmFailureReason"] as? String
    }

    private func requestCameraAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = granted ? .authorized : .denied
        if granted {
            cameras = loadCameras()
            if showPreview, ext.state.isActive, previewSession == nil {
                await startPreviewWithRetry()
            }
        }
    }

    private func relaunchApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: config) { _, _ in }
        NSApp.terminate(nil)
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

    private func startPreviewWithRetry() async {
        // CMIOExtension device may take several seconds to appear in the discovery
        // list after activation or reinstall — retry with 500ms gaps up to 6s total.
        for attempt in 0..<12 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
            }
            if startPreview() { return }
            previewLogger.log("startPreview attempt \(attempt) failed, retrying…")
        }
        previewLogger.log("startPreview: all attempts exhausted")
    }

    @discardableResult
    private func startPreview() -> Bool {
        guard previewSession == nil else {
            previewLogger.log("startPreview: already have session")
            return true
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices
        previewLogger.log("startPreview: found \(devices.count) external devices: \(devices.map(\.localizedName).joined(separator: ", "))")
        guard let virtualCam = devices.first(where: { $0.localizedName == "MultiHUD" }) else {
            previewLogger.log("startPreview: MultiHUD not in discovery list")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: virtualCam) else {
            previewLogger.log("startPreview: failed to create AVCaptureDeviceInput")
            return false
        }
        let session = AVCaptureSession()
        guard session.canAddInput(input) else {
            previewLogger.log("startPreview: canAddInput returned false")
            return false
        }
        session.addInput(input)
        previewSession = session
        previewLogger.log("startPreview: session created, starting…")
        Task.detached(priority: .userInitiated) { session.startRunning() }
        return true
    }

    private func stopPreview() {
        previewSession?.stopRunning()
        previewSession = nil
    }
}

// MARK: - PositionGridPicker

private struct PositionGridPicker: View {
    @Binding var position: String

    private struct Cell: Identifiable {
        let id: String   // position tag, or "" for the disabled gap
        let row: Int
        let col: Int
    }

    private let cells: [Cell] = [
        Cell(id: "topLeft",      row: 0, col: 0),
        Cell(id: "topCenter",    row: 0, col: 1),
        Cell(id: "topRight",     row: 0, col: 2),
        Cell(id: "bottomLeft",   row: 1, col: 0),
        Cell(id: "bottomCenter", row: 1, col: 1),
        Cell(id: "bottomRight",  row: 1, col: 2),
    ]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(cells.filter { $0.row == row }) { cell in
                        if cell.id.isEmpty {
                            Color.clear.frame(width: 26, height: 18)
                        } else {
                            let selected = position == cell.id
                            Button {
                                position = cell.id
                            } label: {
                                Circle()
                                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                                    .frame(width: 5, height: 5)
                                    .frame(width: 26, height: 18)
                            }
                            .buttonStyle(.borderless)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                            )
                        }
                    }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(ExtensionManager())
}
