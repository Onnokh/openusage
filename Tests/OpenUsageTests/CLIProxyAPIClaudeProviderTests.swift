import XCTest
@testable import OpenUsage

final class CLIProxyAPIAuthStoreTests: XCTestCase {
    private static let authDir = "/proxy/auth"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    private func accountJSON(
        email: String,
        uuid: String,
        token: String = "access",
        expired: String = "2027-01-15T10:00:00Z",
        disabled: Bool = false,
        type: String = "claude"
    ) -> String {
        #"{"type":"\#(type)","email":"\#(email)","account_uuid":"\#(uuid)","access_token":"\#(token)","refresh_token":"REFRESH_SECRET","expired":"\#(expired)","disabled":\#(disabled)}"#
    }

    private func store(_ files: [String: String], config: String? = nil) -> CLIProxyAPIAuthStore {
        var all = files
        if let config { all["/opt/homebrew/etc/cliproxyapi.conf"] = config }
        let names = files.keys.map { String($0.split(separator: "/").last!) }
        return CLIProxyAPIAuthStore(
            files: FakeFiles(all),
            listDirectory: { $0 == Self.authDir ? names : [] },
            now: { Self.now }
        )
    }

    func testParsesAuthDirFromNestedAndTopLevelConfig() {
        XCTAssertEqual(CLIProxyAPIAuthStore.parseAuthDir("oauth:\n  auth-dir: \"/a/b\" # note\n"), "/a/b")
        XCTAssertEqual(CLIProxyAPIAuthStore.parseAuthDir("port: 8317\nauth-dir: ~/.cli-proxy-api\n"), "~/.cli-proxy-api")
        XCTAssertNil(CLIProxyAPIAuthStore.parseAuthDir("port: 8317\n"))
    }

    func testFallsBackToUpstreamDefaultAuthDirWithoutConfig() {
        XCTAssertEqual(store([:]).authDir(), CLIProxyAPIAuthStore.defaultAuthDir)
    }

    func testDiscoversOnlyClaudeAccountsSortedByEmail() {
        let s = store([
            "\(Self.authDir)/claude-1-zed@x.nl.json": accountJSON(email: "zed@x.nl", uuid: "u-zed"),
            "\(Self.authDir)/claude-2-amy@x.nl.json": accountJSON(email: "amy@x.nl", uuid: "u-amy"),
            "\(Self.authDir)/codex-3-bob@x.nl.json": accountJSON(email: "bob@x.nl", uuid: "u-bob", type: "codex")
        ], config: "oauth:\n  auth-dir: \"\(Self.authDir)\"\n")

        let accounts = s.discoverClaudeAccounts()

        XCTAssertEqual(accounts.map(\.email), ["amy@x.nl", "zed@x.nl"])
        XCTAssertEqual(accounts.first?.displayName, "Claude · amy")
        XCTAssertTrue(accounts.first!.providerID.hasPrefix("cliproxyapi-claude-"))
        XCTAssertFalse(accounts.first!.providerID.contains("u-amy")) // raw account id never leaks
        XCTAssertNotEqual(accounts[0].providerID, accounts[1].providerID)
    }

    func testAccessTokenRejectsExpiredAndDisabledAccountsWithoutRefreshing() {
        let path = "\(Self.authDir)/claude-1-a@x.nl.json"
        let ref = CLIProxyAPIClaudeAccountRef(path: path, email: "a@x.nl", accountUUID: "u")

        XCTAssertEqual(try store([path: accountJSON(email: "a@x.nl", uuid: "u")]).accessToken(for: ref), "access")
        XCTAssertThrowsError(try store([path: accountJSON(email: "a@x.nl", uuid: "u", expired: "2027-01-15T07:00:00Z")]).accessToken(for: ref)) {
            XCTAssertEqual($0 as? CLIProxyAPIError, .tokenExpired)
        }
        XCTAssertThrowsError(try store([path: accountJSON(email: "a@x.nl", uuid: "u", disabled: true)]).accessToken(for: ref)) {
            XCTAssertEqual($0 as? CLIProxyAPIError, .accountDisabled)
        }
        XCTAssertThrowsError(try store([:]).accessToken(for: ref)) {
            XCTAssertEqual($0 as? CLIProxyAPIError, .accountMissing)
        }
    }
}

@MainActor
final class CLIProxyAPIClaudeProviderTests: XCTestCase {
    private let path = "/proxy/auth/claude-1-onno@x.nl.json"
    private static let usageBody = #"{"five_hour":{"utilization":42,"resets_at":"2100-01-01T00:00:00Z"},"seven_day":{"utilization":10}}"#
    private static let maxProfileBody = #"{"account":{"uuid":"u"},"organization":{"uuid":"o","organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#

    /// `responses` maps a request path ("/api/oauth/usage") to its status and body.
    private func makeProvider(_ responses: [String: (Int, String)]) -> (CLIProxyAPIClaudeProvider, RoutingHTTPClient) {
        let files = FakeFiles([
            path: #"{"type":"claude","email":"onno@x.nl","account_uuid":"u","access_token":"proxy-token","refresh_token":"r","expired":"2100-01-01T00:00:00Z"}"#
        ])
        let http = RoutingHTTPClient { request in
            let (status, body) = responses[request.url.path] ?? (404, "{}")
            return HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
        }
        let provider = CLIProxyAPIClaudeProvider(
            account: CLIProxyAPIClaudeAccountRef(path: path, email: "onno@x.nl", accountUUID: "u"),
            authStore: CLIProxyAPIAuthStore(files: files, listDirectory: { _ in [] }),
            usageClient: ClaudeUsageClient(httpClient: http)
        )
        return (provider, http)
    }

    func testMapsLiveUsageWithTheProxyTokenAndNeverRefreshesIt() async {
        let (provider, http) = makeProvider([
            "/api/oauth/usage": (200, Self.usageBody),
            "/api/oauth/profile": (200, Self.maxProfileBody)
        ])

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/usage", "/api/oauth/profile"]) // never a token refresh
        XCTAssertEqual(Set(http.requests.map { $0.headers["Authorization"] }), ["Bearer proxy-token"])
    }

    func testShowsThePlanFromTheProfileAndLooksItUpOnlyOnce() async {
        let (provider, http) = makeProvider([
            "/api/oauth/usage": (200, Self.usageBody),
            "/api/oauth/profile": (200, Self.maxProfileBody)
        ])

        let first = await provider.refresh()
        let second = await provider.refresh()

        XCTAssertEqual(first.plan, "Max 20x")
        XCTAssertEqual(second.plan, "Max 20x")
        XCTAssertEqual(http.requests.filter { $0.url.path == "/api/oauth/profile" }.count, 1)
    }

    func testFailedProfileKeepsTheUsageBarsAndRetriesNextRefresh() async {
        let (provider, http) = makeProvider([
            "/api/oauth/usage": (200, Self.usageBody),
            "/api/oauth/profile": (500, "{}")
        ])

        let first = await provider.refresh()
        _ = await provider.refresh()

        XCTAssertNil(first.errorCategory)
        XCTAssertNil(first.plan)
        XCTAssertNotNil(first.line(label: "Session"))
        XCTAssertEqual(http.requests.filter { $0.url.path == "/api/oauth/profile" }.count, 2)
    }

    func testRejectedTokenPointsAtCLIProxyAPIInsteadOfRefreshing() async {
        let (provider, http) = makeProvider(["/api/oauth/usage": (401, "{}")])

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(
            snapshot.line(label: MetricLine.errorBadgeLabel),
            .badge(label: MetricLine.errorBadgeLabel, text: CLIProxyAPIError.tokenRejected.errorDescription!, colorHex: "#EF4444")
        )
        XCTAssertEqual(http.requests.count, 1)
    }
}
