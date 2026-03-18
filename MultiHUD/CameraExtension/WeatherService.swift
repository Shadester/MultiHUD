//
//  WeatherService.swift
//  CameraExtension
//
//  Reads weather text written by the host app into the shared app group container.
//

import Foundation

private let kAppGroup = "HGS3GTCF73.net.fakeapps.MultiHUD"

private let sharedWeatherFileURL: URL? =
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup)?
        .appendingPathComponent("weather.txt")

final class WeatherService {

    static let shared = WeatherService()

    private(set) var overlayText: String = "…" {
        didSet { onUpdate?(overlayText) }
    }

    var onUpdate: ((String) -> Void)? {
        didSet { onUpdate?(overlayText) }
    }

    private var timer: DispatchSourceTimer?

    private init() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(30))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    private func poll() {
        guard let url = sharedWeatherFileURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != overlayText {
            overlayText = trimmed
        }
    }
}
