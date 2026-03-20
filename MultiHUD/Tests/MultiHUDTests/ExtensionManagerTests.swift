//
//  ExtensionManagerTests.swift
//  MultiHUDTests
//

import Testing
@testable import MultiHUD

@Suite("ExtensionManager.State")
struct ExtensionManagerTests {

    @Test("label for every state")
    func labels() {
        #expect(ExtensionManager.State.unknown.label        == "Not installed")
        #expect(ExtensionManager.State.installing.label     == "Installing…")
        #expect(ExtensionManager.State.uninstalling.label   == "Uninstalling…")
        #expect(ExtensionManager.State.active.label         == "Active")
        #expect(ExtensionManager.State.rebootRequired.label == "Reboot required to complete")
        #expect(ExtensionManager.State.approvalNeeded.label == "Approval needed in System Settings")
        #expect(ExtensionManager.State.failed("msg").label  == "Error: msg")
    }

    @Test("isActive true only for .active")
    func isActive() {
        let states: [ExtensionManager.State] = [
            .unknown, .installing, .uninstalling, .active,
            .rebootRequired, .approvalNeeded, .failed("x")
        ]
        for state in states {
            if case .active = state {
                #expect(state.isActive)
            } else {
                #expect(!state.isActive)
            }
        }
    }

    @Test("needsApproval true only for .approvalNeeded")
    func needsApproval() {
        #expect(ExtensionManager.State.approvalNeeded.needsApproval)
        #expect(!ExtensionManager.State.unknown.needsApproval)
        #expect(!ExtensionManager.State.active.needsApproval)
        #expect(!ExtensionManager.State.installing.needsApproval)
        #expect(!ExtensionManager.State.failed("x").needsApproval)
    }

    @Test("needsReboot true only for .rebootRequired")
    func needsReboot() {
        #expect(ExtensionManager.State.rebootRequired.needsReboot)
        #expect(!ExtensionManager.State.unknown.needsReboot)
        #expect(!ExtensionManager.State.active.needsReboot)
        #expect(!ExtensionManager.State.approvalNeeded.needsReboot)
    }

    @Test("isBusy true for installing and uninstalling only")
    func isBusy() {
        #expect(ExtensionManager.State.installing.isBusy)
        #expect(ExtensionManager.State.uninstalling.isBusy)
        #expect(!ExtensionManager.State.unknown.isBusy)
        #expect(!ExtensionManager.State.active.isBusy)
        #expect(!ExtensionManager.State.rebootRequired.isBusy)
        #expect(!ExtensionManager.State.approvalNeeded.isBusy)
        #expect(!ExtensionManager.State.failed("x").isBusy)
    }
}
