//
//  AppSettings.swift
//  MultiHUD
//

import Foundation
import Observation
import os.log

private let kAppGroup = "HGS3GTCF73.net.fakeapps.MultiHUD"

private func appGroupURL(_ name: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup)?
        .appendingPathComponent(name)
}

// MARK: - AppSettings

/// Shared, observable settings object. Instantiated once at the app level and
/// injected into both ContentView instances via the SwiftUI environment.
/// Persists to `settings.json` in the shared app group container.
@Observable @MainActor
final class AppSettings {

    // MARK: General
    var cameraId: String = ""
    var blurBackground: Bool = false
    var segQuality: String = "fast"
    var resolution: String = "720p"

    // MARK: Widgets
    var opacity: Double = 1.0
    var weatherEnabled: Bool = true
    var weatherPosition: String = "bottomLeft"
    var clockEnabled: Bool = false
    var clockPosition: String = "bottomLeft"
    var countupEnabled: Bool = false
    var countupPosition: String = "bottomRight"
    var countupStartedAt: Double = 0
    var countdownEnabled: Bool = false
    var countdownPosition: String = "bottomLeft"
    /// Target end time as a clock time (hour + minute). Not persisted — only `countdownEndsAt` is.
    var countdownEndTime: Date = Date().addingTimeInterval(1800)
    var countdownEndsAt: Double = 0

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Persistence

    func load() {
        guard let url = appGroupURL("settings.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        apply(json)
    }

    func apply(_ json: [String: Any]) {
        cameraId       = json["cameraId"]       as? String ?? ""
        blurBackground = json["blurBackground"] as? Bool   ?? false
        segQuality     = json["segQuality"]     as? String ?? "fast"
        resolution     = json["resolution"]     as? String ?? "720p"
        opacity        = json["opacity"]        as? Double ?? 1.0

        guard let arr = json["widgets"] as? [[String: Any]] else { return }
        for w in arr {
            guard let type     = w["type"]     as? String else { continue }
            let  enabled  = w["enabled"]  as? Bool   ?? false
            let  position = w["position"] as? String ?? "bottomLeft"
            switch type {
            case "weather":
                weatherEnabled = enabled;  weatherPosition = position
            case "clock":
                clockEnabled   = enabled;  clockPosition   = position
            case "countup":
                countupEnabled  = enabled; countupPosition  = position
                countupStartedAt = w["startedAt"] as? Double ?? 0
            case "countdown":
                countdownEnabled = enabled; countdownPosition = position
                countdownEndsAt  = w["endsAt"] as? Double ?? 0
            default:
                break
            }
        }
    }

    func toJSON() -> [String: Any] {
        let widgets: [[String: Any]] = [
            ["type": "weather",   "position": weatherPosition,   "enabled": weatherEnabled],
            ["type": "clock",     "position": clockPosition,     "enabled": clockEnabled],
            ["type": "countup",   "position": countupPosition,   "enabled": countupEnabled,
             "startedAt": countupStartedAt],
            ["type": "countdown", "position": countdownPosition, "enabled": countdownEnabled,
             "endsAt": countdownEndsAt],
        ]
        return [
            "cameraId":       cameraId,
            "blurBackground": blurBackground,
            "segQuality":     segQuality,
            "resolution":     resolution,
            "opacity":        opacity,
            "widgets":        widgets,
        ]
    }

    func save() {
        let json = toJSON()
        guard let url  = appGroupURL("settings.json"),
              let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
        // Write on a background thread to avoid blocking the main queue.
        DispatchQueue.global(qos: .utility).async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                os_log(.error, "MultiHUD: failed to save settings.json: %{public}@",
                       error.localizedDescription)
            }
        }
    }

    // MARK: - Timer actions

    func startCountup() {
        countupStartedAt = Date().timeIntervalSince1970
        save()
    }

    func resetCountup() {
        countupStartedAt = 0
        save()
    }

    func startCountdown() {
        countdownEndsAt = AppSettings.nextOccurrence(of: countdownEndTime).timeIntervalSince1970
        save()
    }

    func resetCountdown() {
        countdownEndsAt = 0
        save()
    }

    // MARK: - Helpers

    static func nextOccurrence(of time: Date, relativeTo now: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.hour, .minute], from: time)
        comps.second = 0
        // Returns today's occurrence if still in the future; tomorrow's otherwise.
        return cal.nextDate(after: now - 1, matching: comps, matchingPolicy: .nextTime) ?? time
    }
}
