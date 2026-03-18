//
//  ExtensionManager.swift
//  MultiHUD
//

import Foundation
import SystemExtensions
import os.log

@Observable
class ExtensionManager: NSObject {

    // Must match the CameraExtension target's bundle identifier exactly
    private let extensionBundleID = Bundle.main.bundleIdentifier.map { $0 + ".CameraExtension" } ?? ""
    private var isInstalling = false

    enum State {
        case unknown, installing, uninstalling, active, failed(String)

        var label: String {
            switch self {
            case .unknown:             return "Not installed"
            case .installing:          return "Installing…"
            case .uninstalling:        return "Uninstalling…"
            case .active:              return "Active"
            case .failed(let msg):     return "Error: \(msg)"
            }
        }

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }

        var needsApproval: Bool {
            if case .failed(let msg) = self { return msg.contains("Approval needed") }
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

    /// Call on app launch to activate (or re-activate after an update) automatically.
    func activate() {
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
            state = .failed("Requires reboot to complete")
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
        state = .failed("Approval needed — open System Settings › Privacy & Security")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }
}
