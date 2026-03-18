//
//  MultiHUDApp.swift
//  MultiHUD
//
//  Created by Erik Lindberg on 2026-03-15.
//

import SwiftUI

@main
struct MultiHUDApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { _ in
                    // Woken by camera extension — weather fetch already running
                }
        }
    }
}
