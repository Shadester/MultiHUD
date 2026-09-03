//
//  ExtensionSettings.swift
//  CameraExtension
//

import Foundation
import CoreGraphics
import Vision

// MARK: - Extension Settings types

internal enum OverlayPosition: String {
    case bottomLeft, bottomRight, topLeft, topRight, bottomCenter, topCenter
}

internal struct OverlayInsets: Equatable {
    let horizontal: CGFloat
    let top: CGFloat
    let bottom: CGFloat
}

internal enum OverlaySafeArea: String {
    case fullFrame, meetingSafe, topStrip, lowerThird

    func insets(for canvasSize: CGSize) -> OverlayInsets {
        let standard: CGFloat = 28
        switch self {
        case .fullFrame:
            return OverlayInsets(horizontal: standard, top: standard, bottom: standard)
        case .meetingSafe:
            // Keeps corner overlays inside a common 4:3 center crop of a 16:9 feed.
            return OverlayInsets(
                horizontal: max(standard, canvasSize.width * 0.125),
                top: max(standard, canvasSize.height * 0.10),
                bottom: max(standard, canvasSize.height * 0.10)
            )
        case .topStrip:
            return OverlayInsets(
                horizontal: max(standard, canvasSize.width * 0.07),
                top: max(standard, canvasSize.height * 0.10),
                bottom: standard
            )
        case .lowerThird:
            return OverlayInsets(
                horizontal: max(standard, canvasSize.width * 0.07),
                top: standard,
                bottom: max(standard, canvasSize.height * 0.12)
            )
        }
    }
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
    var segQuality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced
    var opacity: Double = 1.0
    var overlaySafeArea: OverlaySafeArea = .fullFrame
    var resolution: String = "720p"
    var cameraId: String = ""
    var useRVM: Bool = true
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
        s.blurBackground = json["blurBackground"] as? Bool   ?? false
        s.resolution     = json["resolution"]     as? String ?? "720p"
        s.cameraId       = json["cameraId"]       as? String ?? ""
        s.useRVM         = json["useRVM"]         as? Bool   ?? true
        s.segQuality = {
            switch json["segQuality"] as? String {
            case "accurate": return .accurate
            case "fast":     return .fast
            default:         return .balanced
            }
        }()
        s.opacity = json["opacity"] as? Double ?? 1.0
        s.overlaySafeArea = OverlaySafeArea(rawValue: json["overlaySafeArea"] as? String ?? "") ?? .fullFrame
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
