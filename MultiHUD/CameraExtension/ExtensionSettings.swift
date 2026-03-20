//
//  ExtensionSettings.swift
//  CameraExtension
//

import Foundation
import Vision

// MARK: - Extension Settings types

internal enum OverlayPosition: String {
    case bottomLeft, bottomRight, topLeft, topRight, bottomCenter
}

internal enum WidgetType: String {
    case weather, clock, countup, countdown
}

internal struct WidgetConfig {
    var type: WidgetType
    var position: OverlayPosition
    var enabled: Bool
    var startedAt: Double = 0
    var endsAt: Double = 0
}

internal struct ExtensionSettings {
    var blurBackground: Bool = false
    var segQuality: VNGeneratePersonSegmentationRequest.QualityLevel = .fast
    var opacity: Double = 1.0
    var widgets: [WidgetConfig] = []

    /// Loads settings from the shared app group container.
    static func load() -> ExtensionSettings {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "HGS3GTCF73.net.fakeapps.MultiHUD")?
            .appendingPathComponent("settings.json") else {
            return ExtensionSettings()
        }
        return load(from: url)
    }

    /// Loads settings from an explicit URL — used by tests.
    static func load(from url: URL) -> ExtensionSettings {
        var s = ExtensionSettings()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }
        s.blurBackground = json["blurBackground"] as? Bool ?? false
        s.segQuality = {
            switch json["segQuality"] as? String {
            case "accurate": return .accurate
            case "balanced": return .balanced
            default:         return .fast
            }
        }()
        s.opacity = json["opacity"] as? Double ?? 1.0
        if let arr = json["widgets"] as? [[String: Any]] {
            s.widgets = arr.compactMap { d in
                guard let typeStr = d["type"] as? String,
                      let type    = WidgetType(rawValue: typeStr),
                      let posStr  = d["position"] as? String,
                      let pos     = OverlayPosition(rawValue: posStr) else { return nil }
                let enabled = d["enabled"] as? Bool ?? false
                var w = WidgetConfig(type: type, position: pos, enabled: enabled)
                w.startedAt = d["startedAt"] as? Double ?? 0
                w.endsAt    = d["endsAt"]    as? Double ?? 0
                return w
            }
        }
        return s
    }
}
