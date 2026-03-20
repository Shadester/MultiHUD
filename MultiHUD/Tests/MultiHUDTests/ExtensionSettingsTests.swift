//
//  ExtensionSettingsTests.swift
//  MultiHUDTests
//

import Testing
import Foundation
import Vision

@Suite("ExtensionSettings")
struct ExtensionSettingsTests {

    private func writeTempJSON(_ json: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        return url
    }

    @Test("Valid full JSON populates all fields")
    func validFullJSON() throws {
        let json: [String: Any] = [
            "blurBackground": true,
            "segQuality": "accurate",
            "opacity": 0.75,
            "widgets": [
                ["type": "weather",   "position": "bottomLeft",  "enabled": true,  "startedAt": 0.0,   "endsAt": 0.0],
                ["type": "clock",     "position": "topRight",    "enabled": false, "startedAt": 0.0,   "endsAt": 0.0],
                ["type": "countup",   "position": "bottomRight", "enabled": true,  "startedAt": 100.0, "endsAt": 0.0],
                ["type": "countdown", "position": "topLeft",     "enabled": true,  "startedAt": 0.0,   "endsAt": 500.0],
            ] as [[String: Any]]
        ]
        let url = try writeTempJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let s = ExtensionSettings.load(from: url)

        #expect(s.blurBackground == true)
        #expect(s.segQuality == .accurate)
        #expect(s.opacity == 0.75)
        #expect(s.widgets.count == 4)

        let countup = try #require(s.widgets.first { $0.type == .countup })
        #expect(countup.startedAt == 100.0)

        let countdown = try #require(s.widgets.first { $0.type == .countdown })
        #expect(countdown.endsAt == 500.0)
    }

    @Test("Missing file returns defaults")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")
        let s = ExtensionSettings.load(from: url)

        #expect(s.blurBackground == false)
        #expect(s.segQuality == .fast)
        #expect(s.opacity == 1.0)
        #expect(s.widgets.isEmpty)
    }

    @Test("Malformed JSON returns defaults")
    func malformedJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try "not json at all!".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let s = ExtensionSettings.load(from: url)

        #expect(s.blurBackground == false)
        #expect(s.opacity == 1.0)
        #expect(s.widgets.isEmpty)
    }

    @Test("segQuality mapping")
    func segQualityMapping() throws {
        let cases: [(String, VNGeneratePersonSegmentationRequest.QualityLevel)] = [
            ("accurate", .accurate),
            ("balanced", .balanced),
            ("fast",     .fast),
            ("unknown",  .fast),
        ]
        for (input, expected) in cases {
            let url = try writeTempJSON(["segQuality": input])
            defer { try? FileManager.default.removeItem(at: url) }
            let s = ExtensionSettings.load(from: url)
            #expect(s.segQuality == expected)
        }
    }

    @Test("Partial widget config defaults startedAt/endsAt to 0")
    func partialWidgetConfig() throws {
        let json: [String: Any] = [
            "widgets": [
                ["type": "countup", "position": "bottomLeft", "enabled": true]
            ] as [[String: Any]]
        ]
        let url = try writeTempJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let s = ExtensionSettings.load(from: url)
        let w = try #require(s.widgets.first)
        #expect(w.startedAt == 0.0)
        #expect(w.endsAt == 0.0)
    }

    @Test("Invalid widget type or position is filtered out")
    func invalidWidgetFiltered() throws {
        let json: [String: Any] = [
            "widgets": [
                ["type": "invalid", "position": "bottomLeft", "enabled": true],
                ["type": "clock",   "position": "badPos",     "enabled": true],
                ["type": "weather", "position": "topLeft",    "enabled": true],
            ] as [[String: Any]]
        ]
        let url = try writeTempJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let s = ExtensionSettings.load(from: url)
        #expect(s.widgets.count == 1)
        #expect(s.widgets[0].type == .weather)
    }
}
