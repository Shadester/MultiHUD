//
//  ExtensionManager.swift
//  MultiHUD
//

import Foundation
import SystemExtensions
import os.log

@Observable
class ExtensionManager: NSObject {

    private let extensionBundleID: String = {
        guard let id = Bundle.main.bundleIdentifier else {
            fatalError("Bundle.main.bundleIdentifier is nil — check the app's Info.plist")
        }
        return id + ".CameraExtension"
    }()

    private var isInstalling = false

    enum State {
        case unknown, installing, uninstalling, active, rebootRequired, approvalNeeded, failed(String)

        var label: String {
            switch self {
            case .unknown:             return "Not installed"
            case .installing:          return "Installing…"
            case .uninstalling:        return "Uninstalling…"
            case .active:              return "Active"
            case .rebootRequired:      return "Reboot required to complete"
            case .approvalNeeded:      return "Approval needed in System Settings"
            case .failed(let msg):     return "Error: \(msg)"
            }
        }

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }

        var needsApproval: Bool {
            if case .approvalNeeded = self { return true }
            return false
        }

        var needsReboot: Bool {
            if case .rebootRequired = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .installing, .uninstalling: return true
            default: return false
            }
        }
    }

    var state: State = .unknown
    /// True only when the extension was freshly approved by the user in this session.
    /// Remains false on normal re-activations so the host app doesn't relaunch unnecessarily.
    private(set) var justInstalled = false

    /// Activates (or re-activates after an update) the extension. Safe to call multiple times.
    func activate() {
        guard !state.isBusy else { return }
        install()
    }

    func install() {
        state = .installing
        isInstalling = true
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        state = .uninstalling
        isInstalling = false
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension ExtensionManager: OSSystemExtensionRequestDelegate {

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            state = isInstalling ? .active : .unknown
        case .willCompleteAfterReboot:
            state = .rebootRequired
        @unknown default:
            state = isInstalling ? .active : .unknown
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        let ns = error as NSError
        let detail = "\(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code) extensionID=\(request.identifier)]"
        os_log(.error, "MultiHUD extension request failed: %{public}@", detail)
        state = .failed(detail)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        justInstalled = true
        state = .approvalNeeded
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }
}
