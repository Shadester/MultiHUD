//
//  WeatherService.swift
//  MultiHUD
//

import Foundation
import WeatherKit
import CoreLocation
import Observation
import os.log

private let kAppGroup = "HGS3GTCF73.net.fakeapps.MultiHUD"

private let sharedWeatherFileURL: URL? =
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup)?
        .appendingPathComponent("weather.txt")

@Observable
@MainActor
final class HostWeatherService: NSObject {

    static let shared = HostWeatherService()

    var locationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private let weatherKit = WeatherKit.WeatherService.shared
    private var refreshTask: Task<Void, Never>?

    private override init() {
        super.init()
        locationStatus = locationManager.authorizationStatus
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        // If location is already authorized, start immediately — the delegate
        // won't fire again just because we re-created the CLLocationManager.
        switch locationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    /// Call from a button tap so the dialog appears with a visible window.
    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    private func fetch(for location: CLLocation) {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                var sleepSeconds: Int = 600
                do {
                    let weather = try await weatherKit.weather(for: location)
                    let current  = weather.currentWeather
                    let tempC = Int(current.temperature.converted(to: .celsius).value)
                    let tempF = Int(current.temperature.converted(to: .fahrenheit).value)
                    write("\(tempC)|\(tempF)|\(current.symbolName)")
                } catch {
                    os_log(.error, "MultiHUD WeatherService: %{public}@", error.localizedDescription)
                    sleepSeconds = 60  // retry sooner after a network error
                }
                try? await Task.sleep(for: .seconds(sleepSeconds))
            }
        }
    }

    private func write(_ text: String) {
        guard let url = sharedWeatherFileURL else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension HostWeatherService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            manager.stopUpdatingLocation()
            self.fetch(for: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        os_log(.error, "MultiHUD location error: %{public}@", error.localizedDescription)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.locationStatus = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            default:
                break
            }
        }
    }
}
