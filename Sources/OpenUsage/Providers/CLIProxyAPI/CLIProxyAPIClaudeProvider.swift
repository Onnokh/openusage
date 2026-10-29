import Foundation

/// One card per Claude account logged in to CLIProxyAPI. Uses the same live usage endpoint and mapper as
/// `ClaudeProvider`, but reads its token from the proxy's auth file and never refreshes it — CLIProxyAPI
/// owns the token lifecycle. No spend/trend tiles: those come from local Claude Code logs, which can't be
/// split per account.
@MainActor
final class CLIProxyAPIClaudeProvider: ProviderRuntime {
    let provider: Provider
    let account: CLIProxyAPIClaudeAccountRef
    let authStore: CLIProxyAPIAuthStore
    let usageClient: ClaudeUsageClient
    let now: @Sendable () -> Date

    /// Same 429 handling as `ClaudeProvider`: serve the last-good bars during a cooldown instead of
    /// blanking the card or piling more requests onto a limiting endpoint.
    private var lastGoodUsage: ClaudeMappedUsage?
    private var rateLimitedUntil: Date?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    /// Plan label ("Max 20x"), looked up once from the OAuth profile: the CLIProxyAPI auth file has no
    /// `subscriptionType`, which is where the main Claude card gets its label.
    private var plan: String?

    init(
        account: CLIProxyAPIClaudeAccountRef,
        authStore: CLIProxyAPIAuthStore = CLIProxyAPIAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.account = account
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        self.provider = Provider(
            id: account.providerID,
            displayName: account.displayName,
            icon: .providerMark("claude"),
            links: [
                .init(label: "Status", url: "https://status.anthropic.com/"),
                .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
            ]
        )
    }

    /// One provider per account currently in the CLIProxyAPI auth dir. Read once at launch, because the
    /// widget registry is fixed for the life of the process. An account also signed in to Claude Code
    /// keeps its card too: the main Claude card can be turned off, and then it would show nowhere.
    static func discover(authStore: CLIProxyAPIAuthStore = CLIProxyAPIAuthStore()) -> [CLIProxyAPIClaudeProvider] {
        authStore.discoverClaudeAccounts().map { CLIProxyAPIClaudeProvider(account: $0, authStore: authStore) }
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", sessionStartSignal: .missingResetDate),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable"),
            .percent(id: "\(provider.id).sonnet", provider: provider, title: "Sonnet"),
            .boundedDollars(id: "\(provider.id).extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
        ]
    }

    /// Layout defaults: every meter on; Session, Weekly and Fable above the fold; only Session pinned, so
    /// several accounts don't flood the menu bar.
    var defaultMetricIDs: [String] { widgetDescriptors.map(\.id) }
    var defaultExpandedMetricIDs: [String] { ["\(provider.id).sonnet", "\(provider.id).extra"] }
    var defaultPinnedMetricIDs: [String] { ["\(provider.id).session"] }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore, account] in authStore.loadAccount(path: account.path) != nil }
    }

    func refresh() async -> ProviderSnapshot {
        let start = Date()
        do {
            let token = try await loadOffMainActor { [authStore, account] in
                Result { try authStore.accessToken(for: account) }
            }.get()
            let mapped = try await fetchUsage(token: token)
            if plan == nil {
                plan = await fetchPlan(token: token)
            }
            var lines = mapped.lines
            MetricLine.appendNoDataIfNeeded(&lines)
            AppLog.info(LogTag.plugin(provider.id), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
            return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: now())
        } catch {
            AppLog.warn(LogTag.plugin(provider.id), "refresh failed: \(error.localizedDescription)")
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func fetchUsage(token: String) async throws -> ClaudeMappedUsage {
        let credentials = ClaudeOAuth(accessToken: token)
        if let until = rateLimitedUntil, now() < until {
            return rateLimitedSnapshot(credentials: credentials, retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up)))
        }

        let response = try await usageClient.fetchUsage(accessToken: token, config: ClaudeAuthStore().oauthConfig())
        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            rateLimitedUntil = now().addingTimeInterval(TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown)))
            return rateLimitedSnapshot(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }

        do {
            let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: credentials, now: now())
            lastGoodUsage = mapped
            rateLimitedUntil = nil
            return mapped
        } catch ClaudeAuthError.tokenExpired {
            // The mapper's message tells the user to run `claude`, which can't fix a proxy-held token.
            throw CLIProxyAPIError.tokenRejected
        }
    }

    /// The plan label never blocks the usage bars: on failure the card shows no label, and the next
    /// refresh tries again.
    private func fetchPlan(token: String) async -> String? {
        do {
            let response = try await usageClient.fetchProfile(accessToken: token, config: ClaudeAuthStore().oauthConfig())
            let profile = try ClaudeUsageClient.decodeProfile(response)
            guard let plan = ClaudeUsageMapper.formatLivePlan(profile: profile, credentials: ClaudeOAuth(accessToken: token)) else {
                AppLog.warn(LogTag.plugin(provider.id), "profile response has no organization plan")
                return nil
            }
            return plan
        } catch {
            AppLog.warn(LogTag.plugin(provider.id), "profile request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func rateLimitedSnapshot(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        guard var mapped = lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        return mapped
    }
}
