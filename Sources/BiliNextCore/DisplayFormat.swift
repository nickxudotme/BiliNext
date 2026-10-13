import Foundation

/// Bilibili-style compact text for counts and publish dates.
public enum DisplayFormat {
    /// 9999 stays exact; 12345 becomes 1.2万 and 123456789 becomes 1.2亿.
    public static func count(_ value: Double) -> String {
        func trimmed(_ number: Double) -> String {
            let text = String(format: "%.1f", number)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        if value >= 100_000_000 { return trimmed(value / 100_000_000) + "亿" }
        if value >= 10_000 { return trimmed(value / 10_000) + "万" }
        return String(Int(value))
    }

    public static func count(_ text: String) -> String {
        Double(text).map(count) ?? text
    }

    /// 刚刚, N分钟前, N小时前, 昨天, MM-dd this year, otherwise yyyy-MM-dd.
    public static func relativeDate(
        _ date: Date, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟前" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))小时前" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "昨天"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
        if parts.year == calendar.component(.year, from: now) { return month }
        return "\(parts.year ?? 0)-" + month
    }

    /// Accepts Unix seconds as a number or string; zero and missing values mean unknown.
    static func date(fromUnix value: Any?) -> Date? {
        let seconds = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
