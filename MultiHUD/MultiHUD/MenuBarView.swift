//
//  MenuBarView.swift
//  MultiHUD
//

import SwiftUI
import AppKit

struct MenuBarView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ExtensionManager.self) private var ext

    var body: some View {
        let s = Bindable(settings)
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ext.state.isActive ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(ext.state.isActive ? "MultiHUD Active" : ext.state.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ext.state.isActive ? .primary : .secondary)
                }
                Spacer()
                Button("Open") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        NSWorkspace.shared.open(Bundle.main.bundleURL)
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Quick settings
            VStack(alignment: .leading, spacing: 4) {
                Text("CAMERA")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Blur background", isOn: s.blurBackground)
                    .onChange(of: settings.blurBackground) { _, _ in settings.save() }

                Divider().padding(.vertical, 2)

                Text("WIDGETS")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Weather", isOn: s.weatherEnabled)
                    .onChange(of: settings.weatherEnabled) { _, _ in settings.save() }

                Toggle("Clock", isOn: s.clockEnabled)
                    .onChange(of: settings.clockEnabled) { _, _ in settings.save() }

                Toggle("Meeting timer", isOn: s.countupEnabled)
                    .onChange(of: settings.countupEnabled) { _, _ in settings.save() }

                HStack(spacing: 6) {
                    Button(settings.countupStartedAt > 0 ? "Restart" : "Start") {
                        settings.startCountup()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                    .disabled(!settings.countupEnabled)
                    Button("Reset") { settings.resetCountup() }
                        .controlSize(.mini)
                        .disabled(settings.countupStartedAt == 0)
                }
                .padding(.leading, 20)

                Toggle("Countdown", isOn: s.countdownEnabled)
                    .onChange(of: settings.countdownEnabled) { _, _ in settings.save() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .controlSize(.small)

            Divider()

            // Opacity
            HStack(spacing: 8) {
                Text("Opacity")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(value: s.opacity, in: 0.1...1.0, step: 0.05)
                    .onChange(of: settings.opacity) { _, _ in settings.save() }
                Text("\(Int(settings.opacity * 100))%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Extension actions (install/approve only — uninstall is in the main window)
            if !ext.state.isActive {
                Divider()
                Group {
                    if ext.state.needsApproval {
                        Button("Approve in System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                    } else {
                        Button("Install Camera Extension") { ext.install() }
                    }
                }
                .disabled(ext.state.isBusy)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            Button("Quit MultiHUD") { NSApp.terminate(nil) }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
    }
}
