//
//  MultiHUDApp.swift
//  MultiHUD
//

import SwiftUI
import AppKit
import Darwin

enum SingleInstance {
    private static var lockFileDescriptor: Int32 = -1

    static func acquire() -> Bool {
        guard lockFileDescriptor == -1,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "HGS3GTCF73.net.fakeapps.MultiHUD"
              ) else { return true } // Fail open if the app group is unavailable.
        let lockURL = container.appendingPathComponent("host.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd != -1 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFileDescriptor = fd
        return true
    }

    /// Releases the advisory lock just before an intentional app relaunch.
    static func release() {
        guard lockFileDescriptor != -1 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }
}

@main
struct MultiHUDApp: App {

    init() {
        // Unit tests load the host app inside an XCTest runner; they must not
        // contend with the installed app's lock or terminate their own runner.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if SingleInstance.acquire() { return }
        // A host is already running. Bring it forward and leave this duplicate.
        DispatchQueue.main.async {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let bundleID = Bundle.main.bundleIdentifier ?? "net.fakeapps.MultiHUD"
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != ownPID }?
                .activate(options: [])
            NSApp.terminate(nil)
        }
    }

    // Single instances shared across both ContentViews via the environment.
    @State private var settings = AppSettings()
    @State private var ext = ExtensionManager()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(settings)
                .environment(ext)
                .onOpenURL { _ in
                    // Woken by camera extension — weather fetch already running.
                }
                .task {
                    ext.activate()
                    _ = HostWeatherService.shared
                }
        }

        MenuBarExtra("MultiHUD", systemImage: "camera.filters") {
            MenuBarView()
                .environment(settings)
                .environment(ext)
        }
        .menuBarExtraStyle(.window)
    }
}
