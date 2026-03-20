//
//  DurationFormatterTests.swift
//  MultiHUDTests
//

import Testing

@Suite("formatDuration")
struct DurationFormatterTests {

    @Test("zero seconds")
    func zero() {
        #expect(formatDuration(0) == "0:00")
    }

    @Test("one second")
    func oneSecond() {
        #expect(formatDuration(1) == "0:01")
    }

    @Test("59 seconds")
    func fiftyNineSeconds() {
        #expect(formatDuration(59) == "0:59")
    }

    @Test("60 seconds")
    func sixtySeconds() {
        #expect(formatDuration(60) == "1:00")
    }

    @Test("3599 seconds")
    func justUnderOneHour() {
        #expect(formatDuration(3599) == "59:59")
    }

    @Test("3600 seconds")
    func oneHour() {
        #expect(formatDuration(3600) == "1:00:00")
    }

    @Test("3661 seconds")
    func oneHourOneMinuteOneSecond() {
        #expect(formatDuration(3661) == "1:01:01")
    }

    @Test("86399 seconds")
    func justUnderOneDay() {
        #expect(formatDuration(86399) == "23:59:59")
    }

    @Test("negative seconds clamp to zero")
    func negative() {
        #expect(formatDuration(-5) == "0:00")
    }
}
