//
//  StatusBarController.swift
//  MultiHUD
//

import AppKit
import SwiftUI

/// AppKit-backed status item so the interactive controls open in one click.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(settings: AppSettings, extensionManager: ExtensionManager) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "camera.filters", accessibilityDescription: "MultiHUD")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(togglePopover(_:))

        popover.behavior = .transient
        popover.animates = true
        let content = MenuBarView()
            .environment(settings)
            .environment(extensionManager)
        popover.contentViewController = NSHostingController(rootView: content)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

@MainActor
final class MultiHUDAppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let extensionManager = ExtensionManager()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(
            settings: settings,
            extensionManager: extensionManager
        )
    }
}
