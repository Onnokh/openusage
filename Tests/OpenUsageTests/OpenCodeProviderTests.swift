import XCTest
@testable import OpenUsage

final class OpenCodeProviderTests: XCTestCase {
    private let authPath = OpenCodeAuthStore.authPath
    private let dbPath = OpenCodeUsageClient.dbPath

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
    }

    private func ms(_ iso: String) -> Int64 {
        Int64((date(iso).timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Auth store

    func testReadsOpenCodeGoKeyFromAuthFile() {
        let store = OpenCodeAuthStore(files: FakeFiles([
            authPath: #"{"opencode-go":{"type":"api-key","key":"go-key"}}"#
        ]))
        XCTAssertEqual(store.loadAuthKey(), "go-key")
    }

    func testIgnoresMissingOrEmptyKey() {
        XCTAssertNil(OpenCodeAuthStore(files: FakeFiles()).loadAuthKey())
        XCTAssertNil(OpenCodeAuthStore(files: FakeFiles([
            authPath: #"{"opencode-go":{"key":"   "}}"#
        ])).loadAuthKey())
        XCTAssertNil(OpenCodeAuthStore(files: FakeFiles([
            authPath: #"{"some-other-provider":{"key":"x"}}"#
        ])).loadAuthKey())
    }

    // MARK: - Usage client parsing

    func testParsesHistoryRowsAndDropsInvalid() {
        let rows = OpenCodeUsageClient.parseRows("""
        1740000000000|2.181
        1740500000000|0.2
        0|9
        1740600000000|-1
        garbage
        """)
        XCTAssertEqual(rows, [
            OpenCodeUsageRow(createdMs: 1_740_000_000_000, cost: 2.181),
            OpenCodeUsageRow(createdMs: 1_740_500_000_000, cost: 0.2)
        ])
    }

    func testLoadHistoryReturnsNilWhenDatabaseMissing() {
        let client = OpenCodeUsageClient(files: FakeFiles(), sqlite: StubSQLite())
        XCTAssertNil(client.loadHistory())
    }

    func testLoadHistoryReturnsNilOnSQLiteError() {
        let client = OpenCodeUsageClient(files: FakeFiles([dbPath: "db"]), sqlite: ThrowingSQLite())
        XCTAssertNil(client.loadHistory())
    }

    func testLoadHistoryReturnsEmptyWhenReadableButNoRows() {
        let client = OpenCodeUsageClient(files: FakeFiles([dbPath: "db"]), sqlite: StubSQLite(value: nil))
        XCTAssertEqual(client.loadHistory(), [])
    }

    // MARK: - Mapper window math (ported from the legacy plugin tests)

    func testZeroedBarsWhenNoUsage() {
        let lines = OpenCodeUsageMapper.progressLines(rows: [], now: date("2026-03-06T12:00:00.000Z"))
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Monthly"])
        XCTAssertTrue(lines.allSatisfy { line in
            if case .progress(_, let used, _, _, _, _, _) = line { return used == 0 }
            return false
        })
        XCTAssertEqual(resetsAt(lines, "Session"), date("2026-03-06T17:00:00.000Z"))
        XCTAssertEqual(resetsAt(lines, "Weekly"), date("2026-03-09T00:00:00.000Z"))
        XCTAssertEqual(resetsAt(lines, "Monthly"), date("2026-04-01T00:00:00.000Z"))
    }

    func testSessionPercentAndRollingReset() {
        let lines = OpenCodeUsageMapper.progressLines(
            rows: [OpenCodeUsageRow(createdMs: ms("2026-03-06T11:00:00.000Z"), cost: 3)],
            now: date("2026-03-06T12:00:00.000Z")
        )
        XCTAssertEqual(used(lines, "Session"), 25) // $3 of $12
        XCTAssertEqual(resetsAt(lines, "Session"), date("2026-03-06T16:00:00.000Z"))
    }

    func testCountsOnlyRollingFiveHourWindow() {
        let lines = OpenCodeUsageMapper.progressLines(
            rows: [
                OpenCodeUsageRow(createdMs: ms("2026-03-06T06:30:00.000Z"), cost: 9),   // outside 5h
                OpenCodeUsageRow(createdMs: ms("2026-03-06T08:00:00.000Z"), cost: 2.4), // inside
                OpenCodeUsageRow(createdMs: ms("2026-03-06T10:00:00.000Z"), cost: 1.2)  // inside
            ],
            now: date("2026-03-06T12:00:00.000Z")
        )
        XCTAssertEqual(used(lines, "Session"), 30) // ($2.4 + $1.2) of $12
        XCTAssertEqual(resetsAt(lines, "Session"), date("2026-03-06T13:00:00.000Z")) // oldest in-window + 5h
    }

    func testWeeklyUsesUtcMondayBoundaries() {
        let lines = OpenCodeUsageMapper.progressLines(
            rows: [
                OpenCodeUsageRow(createdMs: ms("2026-03-01T23:59:59.000Z"), cost: 10), // prev week
                OpenCodeUsageRow(createdMs: ms("2026-03-02T00:00:00.000Z"), cost: 6),  // Monday start
                OpenCodeUsageRow(createdMs: ms("2026-03-05T09:00:00.000Z"), cost: 3)
            ],
            now: date("2026-03-06T12:00:00.000Z")
        )
        XCTAssertEqual(used(lines, "Weekly"), 30) // ($6 + $3) of $30
        XCTAssertEqual(resetsAt(lines, "Weekly"), date("2026-03-09T00:00:00.000Z"))
    }

    func testMonthlyAnchorsToEarliestLocalUsage() {
        let lines = OpenCodeUsageMapper.progressLines(
            rows: [
                OpenCodeUsageRow(createdMs: ms("2026-02-25T07:53:16.000Z"), cost: 2.181), // anchor
                OpenCodeUsageRow(createdMs: ms("2026-03-01T00:00:00.000Z"), cost: 0.2),
                OpenCodeUsageRow(createdMs: ms("2026-03-04T12:00:00.000Z"), cost: 0.2904)
            ],
            now: date("2026-03-06T12:00:00.000Z")
        )
        XCTAssertEqual(used(lines, "Monthly"), 4.5) // ($2.181 + $0.2 + $0.2904 = $2.6714) of $60 -> 4.45 -> 4.5
        XCTAssertEqual(resetsAt(lines, "Monthly"), date("2026-03-25T07:53:16.000Z"))
        XCTAssertEqual(periodMs(lines, "Monthly"), 28 * 24 * 60 * 60 * 1000)
    }

    func testClampsPercentAt100() {
        let lines = OpenCodeUsageMapper.progressLines(
            rows: [OpenCodeUsageRow(createdMs: ms("2026-03-06T11:00:00.000Z"), cost: 40)],
            now: date("2026-03-06T12:00:00.000Z")
        )
        XCTAssertEqual(used(lines, "Session"), 100)
    }

    // MARK: - Provider integration

    @MainActor
    func testNotDetectedWithoutAuthOrHistory() async {
        let fixedNow = date("2026-03-06T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: OpenCodeAuthStore(files: FakeFiles()),
            usageClient: OpenCodeUsageClient(files: FakeFiles(), sqlite: StubSQLite()),
            now: { fixedNow }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    @MainActor
    func testAuthOnlyShowsZeroedBars() async {
        let fixedNow = date("2026-03-06T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: OpenCodeAuthStore(files: FakeFiles([authPath: #"{"opencode-go":{"key":"go-key"}}"#])),
            usageClient: OpenCodeUsageClient(files: FakeFiles([dbPath: "db"]), sqlite: StubSQLite(value: nil)),
            now: { fixedNow }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(snapshot.lines.map { $0.label }, ["Session", "Weekly", "Monthly"])
        XCTAssertEqual(used(snapshot.lines, "Session"), 0)
    }

    @MainActor
    func testHistoryOnlyEnablesProvider() async {
        let fixedNow = date("2026-03-06T12:00:00.000Z")
        let rowSQL = "\(ms("2026-03-06T11:00:00.000Z"))|3"
        let provider = OpenCodeProvider(
            authStore: OpenCodeAuthStore(files: FakeFiles()),
            usageClient: OpenCodeUsageClient(files: FakeFiles([dbPath: "db"]), sqlite: StubSQLite(value: rowSQL)),
            now: { fixedNow }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(used(snapshot.lines, "Session"), 25)
    }

    @MainActor
    func testSoftEmptyWhenDetectedButDatabaseUnreadable() async {
        let fixedNow = date("2026-03-06T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: OpenCodeAuthStore(files: FakeFiles([authPath: #"{"opencode-go":{"key":"go-key"}}"#])),
            usageClient: OpenCodeUsageClient(files: FakeFiles([dbPath: "db"]), sqlite: ThrowingSQLite()),
            now: { fixedNow }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory) // soft, not a hard failure
        XCTAssertEqual(snapshot.lines, [.noUsageData])
    }

    // MARK: - Helpers

    private func used(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = lines.first(where: { $0.label == label }) else { return nil }
        return used
    }

    private func resetsAt(_ lines: [MetricLine], _ label: String) -> Date? {
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = lines.first(where: { $0.label == label }) else { return nil }
        return resetsAt
    }

    private func periodMs(_ lines: [MetricLine], _ label: String) -> Int? {
        guard case .progress(_, _, _, _, _, let period, _)? = lines.first(where: { $0.label == label }) else { return nil }
        return period
    }
}

private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
    let value: String?
    init(value: String? = nil) { self.value = value }
    func queryValue(path: String, sql: String) throws -> String? { value }
    func execute(path: String, sql: String) throws {}
}

private final class ThrowingSQLite: SQLiteAccessing, @unchecked Sendable {
    func queryValue(path: String, sql: String) throws -> String? {
        throw SQLiteError.queryFailed("disk I/O error")
    }
    func execute(path: String, sql: String) throws {}
}
