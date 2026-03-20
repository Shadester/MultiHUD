//
//  MultiHUDApp.swift
//  MultiHUD
//

import SwiftUI

@main
struct MultiHUDApp: App {

    // Single instances shared across both ContentViews via the environment.
    @State private var settings = AppSettings()
    @State private var ext = ExtensionManager()

    var body: some Scene {
        WindowGroup {
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
            ContentView()
                .environment(settings)
                .environment(ext)
        }
        .menuBarExtraStyle(.window)
    }
}
