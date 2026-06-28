import Foundation

/// OpenCode Go usage, read entirely from the local machine. OpenCode publishes no usage API, so the
/// provider observes spend from OpenCode's own SQLite history and renders it against the published Go
/// plan limits. The provider stays hidden until there's a signal it's in use — either an `opencode-go`
/// key in OpenCode's `auth.json` or existing local OpenCode Go usage.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: OpenCodeAuthStore.providerKey,
        displayName: "OpenCode Go",
        icon: .providerMark(OpenCodeAuthStore.providerKey),
        links: [
            .init(label: "Console", url: "https://opencode.ai/auth"),
            .init(label: "Docs", url: "https://opencode.ai/docs/go/")
        ]
    )

    let authStore: OpenCodeAuthStore
    let usageClient: OpenCodeUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageClient: OpenCodeUsageClient = OpenCodeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly"),
            .percent(id: "\(provider.id).monthly", provider: provider, title: "Monthly")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        // Both reads block on subprocesses (file I/O, the sqlite3 CLI), so run them off the MainActor.
        let authKey = await loadOffMainActor { [authStore] in authStore.loadAuthKey() }
        let rows = await loadOffMainActor { [usageClient] in usageClient.loadHistory() }

        let hasLocalUsage = rows.map { !$0.isEmpty } ?? false
        guard authKey != nil || hasLocalUsage else {
            return ProviderSnapshot.error(provider: provider, error: OpenCodeAuthError.notDetected)
        }

        // Detected (auth or prior history) but the database is currently unreadable: stay visible with a
        // soft status instead of a hard error, per the provider's documented failure behavior.
        guard let rows else {
            return ProviderSnapshot.make(
                provider: provider,
                plan: OpenCodeUsageMapper.plan,
                lines: [.noUsageData],
                refreshedAt: now()
            )
        }

        let lines = OpenCodeUsageMapper.progressLines(rows: rows, now: now())
        return ProviderSnapshot.make(
            provider: provider,
            plan: OpenCodeUsageMapper.plan,
            lines: lines,
            refreshedAt: now()
        )
    }
}
