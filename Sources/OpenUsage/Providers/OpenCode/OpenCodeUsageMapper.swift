import Foundation

/// Turns local OpenCode Go usage rows into the three progress meters OpenUsage shows. OpenCode exposes no
/// account-truth usage, so each bar is *observed local spend* as a percentage of the current published
/// OpenCode Go plan limit, clamped at 100%. Missing remote or other-device usage is not estimated.
///
/// Window rules (ported from the legacy plugin so the numbers stay identical):
/// - **Session** — rolling last 5 hours from now.
/// - **Weekly** — UTC Monday 00:00 through the next UTC Monday 00:00.
/// - **Monthly** — a subscription-style month anchored to the earliest observed local usage timestamp,
///   falling back to UTC calendar-month bounds until the first usage is recorded.
enum OpenCodeUsageMapper {
    static let fiveHoursMs: Int64 = 5 * 60 * 60 * 1000
    static let weekMs: Int64 = 7 * 24 * 60 * 60 * 1000

    /// Current published OpenCode Go plan limits (USD). See https://opencode.ai/docs/go/.
    static let sessionLimit = 12.0
    static let weeklyLimit = 30.0
    static let monthlyLimit = 60.0

    static let plan = "Go"

    static func progressLines(rows: [OpenCodeUsageRow], now: Date) -> [MetricLine] {
        let nowMs = ms(now)

        let sessionStart = nowMs - fiveHoursMs
        let weeklyStart = startOfUtcWeekMs(nowMs)
        let weeklyEnd = weeklyStart + weekMs
        let earliest = rows.map(\.createdMs).min()
        let month = anchoredMonthBounds(nowMs: nowMs, anchorMs: earliest)

        let sessionCost = sumRange(rows, start: sessionStart, end: nowMs)
        let weeklyCost = sumRange(rows, start: weeklyStart, end: weeklyEnd)
        let monthlyCost = sumRange(rows, start: month.start, end: month.end)

        return [
            .progress(
                label: "Session",
                used: clampPercent(sessionCost, sessionLimit),
                limit: 100,
                format: .percent,
                resetsAt: date(ms: nextRollingResetMs(rows, nowMs: nowMs)),
                periodDurationMs: Int(fiveHoursMs)
            ),
            .progress(
                label: "Weekly",
                used: clampPercent(weeklyCost, weeklyLimit),
                limit: 100,
                format: .percent,
                resetsAt: date(ms: weeklyEnd),
                periodDurationMs: Int(weekMs)
            ),
            .progress(
                label: "Monthly",
                used: clampPercent(monthlyCost, monthlyLimit),
                limit: 100,
                format: .percent,
                resetsAt: date(ms: month.end),
                periodDurationMs: Int(month.end - month.start)
            )
        ]
    }

    // MARK: - Aggregation

    /// Spend over `[start, end)`, rounded to 4 decimals to match the legacy plugin's accumulation.
    static func sumRange(_ rows: [OpenCodeUsageRow], start: Int64, end: Int64) -> Double {
        var total = 0.0
        for row in rows where row.createdMs >= start && row.createdMs < end {
            total += row.cost
        }
        return (total * 10000).rounded() / 10000
    }

    /// `used / limit` as a percent clamped to `0...100` and rounded to one decimal. Guards against a
    /// non-positive limit so a misconfigured plan never divides by zero.
    static func clampPercent(_ used: Double, _ limit: Double) -> Double {
        guard used.isFinite, limit.isFinite, limit > 0 else { return 0 }
        let percent = used / limit * 100
        guard percent.isFinite else { return 0 }
        return (min(100, max(0, percent)) * 10).rounded() / 10
    }

    /// When the rolling 5-hour session window next frees up: the oldest message still inside the window,
    /// plus 5 hours. With no activity in the window the session is already clear, so it resets 5h from now.
    static func nextRollingResetMs(_ rows: [OpenCodeUsageRow], nowMs: Int64) -> Int64 {
        let start = nowMs - fiveHoursMs
        var oldest: Int64?
        for row in rows where row.createdMs >= start && row.createdMs < nowMs {
            if oldest == nil || row.createdMs < oldest! { oldest = row.createdMs }
        }
        return (oldest ?? nowMs) + fiveHoursMs
    }

    // MARK: - Calendar windows (all UTC)

    static func startOfUtcWeekMs(_ nowMs: Int64) -> Int64 {
        let now = date(ms: nowMs)
        // Calendar `.weekday` is 1=Sunday…7=Saturday; shift to a Monday-based offset like JS getUTCDay.
        let weekday = cal.component(.weekday, from: now) - 1
        let offset = (weekday + 6) % 7
        let startOfToday = cal.startOfDay(for: now)
        let monday = cal.date(byAdding: .day, value: -offset, to: startOfToday)!
        return ms(monday)
    }

    /// Monthly window bounds. With no anchor (no local usage yet) this is the plain UTC calendar month;
    /// otherwise the window starts on the same day-of-month and time-of-day as the earliest observed
    /// usage, clamped to the target month's length, so a "subscription month" tracks the user's signup day.
    static func anchoredMonthBounds(nowMs: Int64, anchorMs: Int64?) -> (start: Int64, end: Int64) {
        guard let anchorMs else {
            let start = startOfUtcMonth(nowMs)
            let next = cal.date(byAdding: .month, value: 1, to: date(ms: start))!
            return (start, ms(next))
        }

        let anchor = date(ms: anchorMs)
        let anchorDay = cal.component(.day, from: anchor)
        // Time-of-day as integer ms, kept separate from the day so all month math stays exact.
        let timeOfDayMs = anchorMs - ms(cal.startOfDay(for: anchor))

        let nowComps = cal.dateComponents([.year, .month], from: date(ms: nowMs))
        var year = nowComps.year!
        var month = nowComps.month!

        var start = anchorMonthMs(year: year, month: month, anchorDay: anchorDay, timeOfDayMs: timeOfDayMs)
        if start > nowMs {
            let firstOfThis = cal.date(from: DateComponents(timeZone: utc, year: year, month: month, day: 1))!
            let prev = cal.date(byAdding: .month, value: -1, to: firstOfThis)!
            let pc = cal.dateComponents([.year, .month], from: prev)
            year = pc.year!
            month = pc.month!
            start = anchorMonthMs(year: year, month: month, anchorDay: anchorDay, timeOfDayMs: timeOfDayMs)
        }

        let firstOfThis = cal.date(from: DateComponents(timeZone: utc, year: year, month: month, day: 1))!
        let firstOfNext = cal.date(byAdding: .month, value: 1, to: firstOfThis)!
        let nc = cal.dateComponents([.year, .month], from: firstOfNext)
        let end = anchorMonthMs(year: nc.year!, month: nc.month!, anchorDay: anchorDay, timeOfDayMs: timeOfDayMs)
        return (start, end)
    }

    private static func anchorMonthMs(year: Int, month: Int, anchorDay: Int, timeOfDayMs: Int64) -> Int64 {
        let firstOfMonth = cal.date(from: DateComponents(timeZone: utc, year: year, month: month, day: 1))!
        let maxDay = cal.range(of: .day, in: .month, for: firstOfMonth)!.count
        let day = min(anchorDay, maxDay)
        let dayStart = cal.date(from: DateComponents(timeZone: utc, year: year, month: month, day: day))!
        return ms(dayStart) + timeOfDayMs
    }

    private static func startOfUtcMonth(_ nowMs: Int64) -> Int64 {
        let comps = cal.dateComponents([.year, .month], from: date(ms: nowMs))
        let first = cal.date(from: DateComponents(timeZone: utc, year: comps.year, month: comps.month, day: 1))!
        return ms(first)
    }

    // MARK: - Time helpers

    private static let utc = TimeZone(identifier: "UTC")!

    private static var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
