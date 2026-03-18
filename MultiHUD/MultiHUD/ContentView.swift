//
//  ContentView.swift
//  MultiHUD
//

import SwiftUI
import AppKit
import AVFoundation
import CoreLocation

struct ContentView: View {

    @State private var ext = ExtensionManager()
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Environment(\.scenePhase) private var scenePhase

    private var locationStatus: CLAuthorizationStatus {
        HostWeatherService.shared.locationStatus
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("MultiHUD")
                .font(.largeTitle.bold())

            // Extension status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(ext.state.isActive ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(ext.state.label)
                    .foregroundStyle(.secondary)
            }

            // Action button
            if ext.state.isActive {
                Button("Uninstall Camera Extension", role: .destructive) {
                    ext.uninstall()
                }
                .disabled(ext.state.isBusy)
            } else if ext.state.needsApproval {
                Button("Open System Settings → Camera Extensions") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Install Camera Extension") {
                    ext.install()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ext.state.isBusy)
            }

            // Camera permission row
            HStack(spacing: 8) {
                Circle()
                    .fill(cameraStatus == .authorized ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                switch cameraStatus {
                case .authorized:
                    Text("Camera access granted")
                        .foregroundStyle(.secondary)
                case .denied, .restricted:
                    Text("Camera access denied")
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                default:
                    Text("Camera access required")
                        .foregroundStyle(.orange)
                    Button("Grant Access") {
                        Task { await requestCameraAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Location permission row
            HStack(spacing: 8) {
                Circle()
                    .fill(locationStatus == .authorizedAlways ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                switch locationStatus {
                case .authorizedAlways:
                    Text("Location access granted")
                        .foregroundStyle(.secondary)
                case .denied, .restricted:
                    Text("Location access denied")
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Location")!)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                default:
                    Text("Location access required for weather")
                        .foregroundStyle(.orange)
                    Button("Grant Access") {
                        HostWeatherService.shared.requestLocationAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            Divider()

            Text("After installing, select **MultiHUD** as your camera in Zoom, Meet, or any video app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 280)
        .task {
            ext.activate()
            _ = HostWeatherService.shared
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func requestCameraAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = granted ? .authorized : .denied
    }
}

#Preview {
    ContentView()
}
