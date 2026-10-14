import Foundation
import Testing

@testable import BiliNextCore

@Test func countsUseWanAndYiLikeTheOfficialClient() {
    #expect(DisplayFormat.count(9999) == "9999")
    #expect(DisplayFormat.count(10_000) == "1万")
    #expect(DisplayFormat.count(12_345) == "1.2万")
    #expect(DisplayFormat.count(123_456_789) == "1.2亿")
    #expect(DisplayFormat.count("2775") == "2775")
    #expect(DisplayFormat.count("--") == "--")
}

@Test func publishDatesReadRelativeThenCalendar() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let now = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15)))
    func ago(_ seconds: Double) -> String {
        DisplayFormat.relativeDate(now.addingTimeInterval(-seconds), now: now, calendar: calendar)
    }
    #expect(ago(20) == "刚刚")
    #expect(ago(5 * 60) == "5分钟前")
    #expect(ago(3 * 3600) == "3小时前")
    #expect(ago(20 * 3600) == "昨天")
    #expect(ago(3 * 86400) == "10-11")
    #expect(ago(400 * 86400) == "2025-09-09")
}

@Test func unixDatesAcceptNumbersAndStrings() {
    #expect(DisplayFormat.date(fromUnix: NSNumber(value: 1_760_000_000)) != nil)
    #expect(DisplayFormat.date(fromUnix: "1760000000") != nil)
    #expect(DisplayFormat.date(fromUnix: NSNumber(value: 0)) == nil)
    #expect(DisplayFormat.date(fromUnix: nil) == nil)
}
