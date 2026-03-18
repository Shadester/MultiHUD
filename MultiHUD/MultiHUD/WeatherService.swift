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
        if locationStatus == .authorizedAlways {
            locationManager.startUpdatingLocation()
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
                do {
                    let weather = try await weatherKit.weather(for: location)
                    let current  = weather.currentWeather
                    let tempC = Int(current.temperature.converted(to: .celsius).value)
                    let tempF = Int(current.temperature.converted(to: .fahrenheit).value)
                    write("\(tempC)|\(tempF)|\(current.symbolName)")
                } catch {
                    os_log(.error, "MultiHUD WeatherService: %{public}@", error.localizedDescription)
                    write("Weather error: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    private func write(_ text: String) {
        guard let url = sharedWeatherFileURL else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func conditionLabel(_ symbolName: String) -> String {
        switch symbolName {
        case let s where s.hasPrefix("sun"):          return "Sunny"
        case let s where s.hasPrefix("cloud.sun"):   return "Partly Cloudy"
        case let s where s.hasPrefix("cloud.bolt"):  return "Thunderstorm"
        case let s where s.hasPrefix("cloud.rain"),
             let s where s.hasPrefix("cloud.drizzle"): return "Rain"
        case let s where s.hasPrefix("cloud.snow"),
             let s where s.hasPrefix("snow"):        return "Snow"
        case let s where s.hasPrefix("cloud"):       return "Cloudy"
        case let s where s.hasPrefix("wind"):        return "Windy"
        case let s where s.hasPrefix("fog"):         return "Foggy"
        default:                                     return ""
        }
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
