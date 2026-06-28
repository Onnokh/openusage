import Foundation

/// One observed assistant message with a recorded cost, read from OpenCode's local history.
struct OpenCodeUsageRow: Hashable, Sendable {
    /// Epoch milliseconds the message was created.
    var createdMs: Int64
    /// Assistant-side spend in USD for that message.
    var cost: Double
}

/// Reads OpenCode Go usage straight from the local OpenCode SQLite database — OpenCode exposes no usage
/// API, so the only source of truth on this machine is its own history file. Sums are computed in Swift
/// (not SQL) so the windowing logic stays testable and matches the published OpenCode Go plan windows.
struct OpenCodeUsageClient: Sendable {
    static let dbPath = "~/.local/share/opencode/opencode.db"

    /// Assistant messages with a numeric `cost` attributed to the `opencode-go` provider. `time.created`
    /// is preferred, falling back to the row's `time_created` column when the JSON timestamp is absent.
    static let historyRowsSQL = """
    SELECT
      CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
      CAST(json_extract(data, '$.cost') AS REAL) AS cost
    FROM message
    WHERE json_valid(data)
      AND json_extract(data, '$.providerID') = '\(OpenCodeAuthStore.providerKey)'
      AND json_extract(data, '$.role') = 'assistant'
      AND json_type(data, '$.cost') IN ('integer', 'real')
    """

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) {
        self.files = files
        self.sqlite = sqlite
    }

    /// Local OpenCode Go usage rows. Returns `nil` when the database can't be read (missing file or a
    /// SQLite error) so the provider can show a soft "No usage data" state instead of failing hard; an
    /// empty array means the database is readable but holds no OpenCode Go usage yet. A non-`nil`,
    /// non-empty result also doubles as the "in use locally" detection signal.
    func loadHistory() -> [OpenCodeUsageRow]? {
        // Don't query a database that isn't there: the sqlite3 CLI would otherwise create an empty file in
        // the user's OpenCode directory. A missing DB reads the same as unreadable — `nil`.
        guard files.exists(Self.dbPath) else { return nil }

        let raw: String?
        do {
            raw = try sqlite.queryValue(path: Self.dbPath, sql: Self.historyRowsSQL)
        } catch {
            AppLog.warn(LogTag.plugin(OpenCodeAuthStore.providerKey), "sqlite history query failed: \(error.localizedDescription)")
            return nil
        }

        // No rows matched (readable DB, no OpenCode Go usage recorded yet): an empty, successful result.
        guard let raw, !raw.isEmpty else { return [] }

        return Self.parseRows(raw)
    }

    /// Parse the `createdMs|cost` rows the sqlite3 CLI prints (one row per line, columns split on `|`).
    /// Rows with a non-positive timestamp or a negative/unparseable cost are dropped, mirroring the
    /// validation the legacy plugin applied before aggregating.
    static func parseRows(_ raw: String) -> [OpenCodeUsageRow] {
        var rows: [OpenCodeUsageRow] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let createdMs = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
                  createdMs > 0,
                  let cost = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  cost >= 0
            else {
                continue
            }
            rows.append(OpenCodeUsageRow(createdMs: createdMs, cost: cost))
        }
        return rows
    }
}
