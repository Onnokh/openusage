import Foundation
import Observation

/// Which CLIProxyAPI Claude account CLIProxyAPI uses first, and the switch that changes it. The primary
/// account is the one whose priority is above every other account's. Making an account primary sets its
/// priority to 100 and every other account's to 0; turning the primary off sets them all to 0, so
/// CLIProxyAPI spreads requests over all accounts again.
@MainActor
@Observable
final class CLIProxyAPIPrimaryStore {
    nonisolated static let primaryPriority = 100

    /// Card id → account. Empty with fewer than two accounts, where a primary means nothing.
    private let accounts: [String: CLIProxyAPIClaudeAccountRef]
    private let authStore: CLIProxyAPIAuthStore
    private(set) var primaryID: String?

    init(accounts: [CLIProxyAPIClaudeAccountRef], authStore: CLIProxyAPIAuthStore = CLIProxyAPIAuthStore()) {
        self.accounts = accounts.count > 1 ? Dictionary(uniqueKeysWithValues: accounts.map { ($0.providerID, $0) }) : [:]
        self.authStore = authStore
    }

    func hasSwitch(_ providerID: String) -> Bool {
        accounts[providerID] != nil
    }

    /// Re-reads the priorities, which can also change in CLIProxyAPI's own management page.
    func reload() async {
        let accounts = Array(accounts.values)
        primaryID = await loadOffMainActor { [authStore] in
            var priorities: [String: Int] = [:]
            for account in accounts {
                do {
                    priorities[account.providerID] = try authStore.priority(for: account)
                } catch {
                    AppLog.error(LogTag.auth("cliproxyapi"), "couldn't read priority of \(account.providerID): \(error.localizedDescription)")
                }
            }
            return Self.primary(in: priorities)
        }
    }

    func setPrimary(_ providerID: String, _ isPrimary: Bool) async {
        let accounts = Array(accounts.values)
        await loadOffMainActor { [authStore] in
            for account in accounts {
                let priority = isPrimary && account.providerID == providerID ? Self.primaryPriority : 0
                do {
                    try authStore.setPriority(priority, for: account)
                } catch {
                    AppLog.error(LogTag.auth("cliproxyapi"), "couldn't set priority of \(account.providerID): \(error.localizedDescription)")
                }
            }
        }
        // Show what the files hold now, also when a write failed.
        await reload()
    }

    /// The single account with the top priority; `nil` when the top priority is shared.
    nonisolated static func primary(in priorities: [String: Int]) -> String? {
        guard let top = priorities.values.max() else { return nil }
        let leaders = priorities.filter { $0.value == top }
        return leaders.count == 1 ? leaders.first?.key : nil
    }
}
