//
//  AppSettingsTests.swift
//  MultiHUDTests
//

import Testing
@testable import MultiHUD
import Foundation

@MainActor @Suite("AppSettings")
struct AppSettingsTests {

    @Test("JSON round-trip")
    func jsonRoundTrip() {
        let s = AppSettings()
        s.cameraId = "cam-1"
        s.blurBackground = true
        s.segQuality = "accurate"
        s.resolution = "1080p"
        s.opacity = 0.8
        s.weatherEnabled = false
        s.weatherPosition = "topRight"
        s.clockEnabled = true
        s.clockPosition = "topLeft"
        s.countupEnabled = true
        s.countupPosition = "bottomRight"
        s.countupStartedAt = 12345.0
        s.countdownEnabled = true
        s.countdownPosition = "bottomCenter"
        s.countdownEndsAt = 99999.0

        let json = s.toJSON()

        let s2 = AppSettings()
        s2.apply(json)

        #expect(s2.cameraId == "cam-1")
        #expect(s2.blurBackground == true)
        #expect(s2.segQuality == "accurate")
        #expect(s2.resolution == "1080p")
        #expect(s2.opacity == 0.8)
        #expect(s2.weatherEnabled == false)
        #expect(s2.weatherPosition == "topRight")
        #expect(s2.clockEnabled == true)
        #expect(s2.clockPosition == "topLeft")
        #expect(s2.countupEnabled == true)
        #expect(s2.countupPosition == "bottomRight")
        #expect(s2.countupStartedAt == 12345.0)
        #expect(s2.countdownEnabled == true)
        #expect(s2.countdownPosition == "bottomCenter")
        #expect(s2.countdownEndsAt == 99999.0)
    }

    @Test("Partial JSON falls back to defaults")
    func partialJSON() {
        let s = AppSettings()
        // Reset to known state first
        s.opacity = 0.5
        s.weatherEnabled = false

        s.apply([:])

        #expect(s.cameraId == "")
        #expect(s.blurBackground == false)
        #expect(s.segQuality == "fast")
        #expect(s.resolution == "720p")
        #expect(s.opacity == 1.0)
        // weatherEnabled unchanged since no "widgets" key
        #expect(s.weatherEnabled == false)
    }

    @Test("Widget array parsing")
    func widgetParsing() {
        let json: [String: Any] = [
            "widgets": [
                ["type": "weather",   "position": "topLeft",     "enabled": true],
                ["type": "clock",     "position": "topRight",    "enabled": true],
                ["type": "countup",   "position": "bottomRight", "enabled": true,  "startedAt": 111.0],
                ["type": "countdown", "position": "bottomLeft",  "enabled": false, "endsAt": 222.0],
            ] as [[String: Any]]
        ]
        let s = AppSettings()
        s.apply(json)

        #expect(s.weatherEnabled == true)
        #expect(s.weatherPosition == "topLeft")
        #expect(s.clockEnabled == true)
        #expect(s.clockPosition == "topRight")
        #expect(s.countupEnabled == true)
        #expect(s.countupPosition == "bottomRight")
        #expect(s.countupStartedAt == 111.0)
        #expect(s.countdownEnabled == false)
        #expect(s.countdownPosition == "bottomLeft")
        #expect(s.countdownEndsAt == 222.0)
    }

    @Test("nextOccurrence — future time returns same day")
    func nextOccurrenceFuture() throws {
        let cal = Calendar.current
        let now  = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 10, minute: 0)))
        let time = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 14, minute: 0)))

        let result = AppSettings.nextOccurrence(of: time, relativeTo: now)
        let comps  = cal.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        #expect(comps.year == 2026)
        #expect(comps.month == 3)
        #expect(comps.day == 20)
        #expect(comps.hour == 14)
        #expect(comps.minute == 0)
    }

    @Test("nextOccurrence — past time rolls to tomorrow")
    func nextOccurrencePast() throws {
        let cal = Calendar.current
        let now  = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 15, minute: 0)))
        let time = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 14, minute: 0)))

        let result = AppSettings.nextOccurrence(of: time, relativeTo: now)
        let comps  = cal.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        #expect(comps.year == 2026)
        #expect(comps.month == 3)
        #expect(comps.day == 21)
        #expect(comps.hour == 14)
        #expect(comps.minute == 0)
    }

    @Test("nextOccurrence — midnight rolls to next day")
    func nextOccurrenceMidnight() throws {
        let cal = Calendar.current
        let now  = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 23, minute: 0)))
        let time = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 0,  minute: 0)))

        let result = AppSettings.nextOccurrence(of: time, relativeTo: now)
        let comps  = cal.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        #expect(comps.year == 2026)
        #expect(comps.month == 3)
        #expect(comps.day == 21)
        #expect(comps.hour == 0)
        #expect(comps.minute == 0)
    }

    @Test("startCountup sets countupStartedAt to now")
    func startCountup() {
        let s = AppSettings()
        let before = Date().timeIntervalSince1970
        s.startCountup()
        let after = Date().timeIntervalSince1970

        #expect(s.countupStartedAt >= before)
        #expect(s.countupStartedAt <= after)
    }

    @Test("resetCountup clears countupStartedAt")
    func resetCountup() {
        let s = AppSettings()
        s.countupStartedAt = 12345.0
        s.resetCountup()
        #expect(s.countupStartedAt == 0)
    }

    @Test("startCountdown sets countdownEndsAt to nextOccurrence")
    func startCountdown() {
        let s = AppSettings()
        let target = Date().addingTimeInterval(3600)
        s.countdownEndTime = target
        s.startCountdown()

        let expected = AppSettings.nextOccurrence(of: target).timeIntervalSince1970
        #expect(abs(s.countdownEndsAt - expected) < 1.0)
    }

    @Test("resetCountdown clears countdownEndsAt")
    func resetCountdown() {
        let s = AppSettings()
        s.countdownEndsAt = 99999.0
        s.resetCountdown()
        #expect(s.countdownEndsAt == 0)
    }
}
