import Foundation

/// OpenCode has no usage API, so there is nothing to authenticate against — the "auth" here is only a
/// detection signal. OpenCode's CLI writes its provider credentials to `auth.json`; an `opencode-go`
/// entry with a non-empty `key` tells us the user has logged in with OpenCode Go on this machine, so the
/// provider should be visible even before any local usage has been recorded.
struct OpenCodeAuth: Hashable, Sendable {
    var key: String
}

enum OpenCodeAuthError: Error, LocalizedError, Equatable {
    case notDetected

    var errorDescription: String? {
        switch self {
        case .notDetected:
            return "OpenCode Go not detected. Log in with OpenCode Go or use it locally first."
        }
    }
}

struct OpenCodeAuthStore: Sendable {
    static let authPath = "~/.local/share/opencode/auth.json"
    /// The key OpenCode writes under in `auth.json` and stamps onto each message's `providerID`. The
    /// OpenUsage-facing provider id matches it, so this single constant drives both detection and the
    /// SQLite filter (see `OpenCodeUsageClient`).
    static let providerKey = "opencode-go"

    var files: TextFileAccessing

    init(files: TextFileAccessing = LocalTextFileAccessor()) {
        self.files = files
    }

    /// The OpenCode Go API key from `auth.json`, or `nil` when the file is missing, malformed, or has no
    /// `opencode-go` entry. Only the presence of a non-empty key matters; the value is never sent anywhere.
    func loadAuthKey() -> String? {
        guard files.exists(Self.authPath),
              let text = try? files.readText(Self.authPath),
              let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = root[Self.providerKey] as? [String: Any],
              let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            return nil
        }
        return key
    }
}
