import CryptoKit
import Foundation

/// One Claude login stored by CLIProxyAPI (`claude-<id>-<email>.json` in its auth dir). Only the fields
/// OpenUsage needs; the refresh/id tokens are deliberately not decoded — CLIProxyAPI owns the refresh, and
/// rotating its refresh token from here would invalidate the proxy's copy and log the account out of it.
struct CLIProxyAPIClaudeAccount: Decodable, Hashable, Sendable {
    var type: String?
    var email: String?
    var accountUUID: String?
    var accessToken: String?
    /// RFC 3339 expiry of `accessToken` ("2026-10-16T22:59:03+02:00").
    var expired: String?
    var disabled: Bool?

    enum CodingKeys: String, CodingKey {
        case type, email, expired, disabled
        case accountUUID = "account_uuid"
        case accessToken = "access_token"
    }
}

/// A Claude account found at launch: the file it lives in plus the identity used to build its card.
struct CLIProxyAPIClaudeAccountRef: Hashable, Sendable {
    var path: String
    var email: String
    var accountUUID: String

    /// Stable provider id, derived from a hash of the account UUID so the raw account id never reaches
    /// layout storage or telemetry.
    var providerID: String {
        let digest = SHA256.hash(data: Data(accountUUID.utf8))
        return "cliproxyapi-claude-" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    /// Card title: the mailbox part of the email, so two accounts in the same org stay distinguishable.
    var displayName: String {
        let name = email.split(separator: "@").first.map(String.init) ?? email
        return "Claude · \(name)"
    }
}

enum CLIProxyAPIError: Error, LocalizedError, Equatable {
    case accountMissing
    case accountDisabled
    case tokenExpired
    case tokenRejected

    var errorDescription: String? {
        switch self {
        case .accountMissing:
            return "Account is no longer in CLIProxyAPI. Restart OpenUsage to update the list."
        case .accountDisabled:
            return "Account is disabled in CLIProxyAPI."
        case .tokenExpired:
            return "Token expired. Waiting for CLIProxyAPI to refresh it."
        case .tokenRejected:
            return "Token rejected. Log in to this account again in CLIProxyAPI."
        }
    }
}

struct CLIProxyAPIAuthStore: Sendable {
    /// Upstream default when no config sets `auth-dir`.
    static let defaultAuthDir = "~/.cli-proxy-api"
    /// Config locations, in order: Homebrew (Apple silicon, Intel), then the upstream default.
    static let configPaths = [
        "/opt/homebrew/etc/cliproxyapi.conf",
        "/usr/local/etc/cliproxyapi.conf",
        "~/.cli-proxy-api/config.yaml"
    ]

    var files: TextFileAccessing
    var listDirectory: @Sendable (String) -> [String]
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        listDirectory: @escaping @Sendable (String) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: expandHome($0))) ?? []
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.listDirectory = listDirectory
        self.now = now
    }

    /// The auth dir from the first config that sets `auth-dir`, else the upstream default.
    func authDir() -> String {
        for path in Self.configPaths where files.exists(path) {
            if let text = try? files.readText(path), let dir = Self.parseAuthDir(text) {
                return dir
            }
        }
        return Self.defaultAuthDir
    }

    /// Every Claude account in the auth dir, sorted by email for a stable card order. Disabled accounts
    /// are kept so their card explains why it has no data instead of silently vanishing.
    func discoverClaudeAccounts() -> [CLIProxyAPIClaudeAccountRef] {
        let dir = authDir()
        let refs = listDirectory(dir)
            .filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
            .compactMap { name -> CLIProxyAPIClaudeAccountRef? in
                let path = "\(dir)/\(name)"
                guard let account = loadAccount(path: path),
                      account.type == "claude",
                      let uuid = account.accountUUID, !uuid.isEmpty
                else { return nil }
                return CLIProxyAPIClaudeAccountRef(path: path, email: account.email ?? uuid, accountUUID: uuid)
            }
            .sorted { $0.email < $1.email }
        AppLog.info(LogTag.auth("cliproxyapi"), "found \(refs.count) Claude account\(refs.count == 1 ? "" : "s")")
        return refs
    }

    func loadAccount(path: String) -> CLIProxyAPIClaudeAccount? {
        guard files.exists(path), let text = try? files.readText(path) else { return nil }
        return try? JSONDecoder().decode(CLIProxyAPIClaudeAccount.self, from: Data(text.utf8))
    }

    /// The usable access token for `ref`, re-read on every refresh because CLIProxyAPI rotates it.
    /// Never refreshes: an expired token means CLIProxyAPI hasn't rotated it yet.
    func accessToken(for ref: CLIProxyAPIClaudeAccountRef) throws -> String {
        guard let account = loadAccount(path: ref.path),
              let token = account.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw CLIProxyAPIError.accountMissing
        }
        if account.disabled == true {
            throw CLIProxyAPIError.accountDisabled
        }
        if let expired = account.expired, let expiry = OpenUsageISO8601.date(from: expired), expiry <= now() {
            throw CLIProxyAPIError.tokenExpired
        }
        return token
    }

    /// The account's routing priority in CLIProxyAPI. CLIProxyAPI sends requests to the highest priority
    /// that is not cooling down, and reads a missing value as 0. It also accepts the number as a string.
    func priority(for ref: CLIProxyAPIClaudeAccountRef) throws -> Int {
        let object = try jsonObject(path: ref.path)
        return ProviderParse.number(object["priority"]).map { Int($0) } ?? 0
    }

    /// Rewrites only `priority` in the account file and keeps every other field. CLIProxyAPI watches its
    /// auth dir and reloads the file on the rename that `writeText` ends with.
    func setPriority(_ priority: Int, for ref: CLIProxyAPIClaudeAccountRef) throws {
        var object = try jsonObject(path: ref.path)
        object["priority"] = priority
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try files.writeText(ref.path, String(decoding: data, as: UTF8.self))
    }

    private func jsonObject(path: String) throws -> [String: Any] {
        guard let object = ProviderParse.jsonObject(Data(try files.readText(path).utf8)) else {
            throw CLIProxyAPIError.accountMissing
        }
        return object
    }

    /// Reads `auth-dir:` from the YAML config. Both layouts set it as a plain `auth-dir: "<path>"` line
    /// (top-level in older configs, under `oauth:` in newer ones), so a line match covers both without a
    /// YAML dependency.
    static func parseAuthDir(_ yaml: String) -> String? {
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("auth-dir:") else { continue }
            var value = line.dropFirst("auth-dir:".count).trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
