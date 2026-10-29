import Foundation
import Observation

/// One-time dashboard notices. The first-run Customize hint: `FirstRunSeeder` marks it pending when it
/// seeds a fresh install's provider set (existing installs are never seeded, so they never see the card);
/// it clears when the user dismisses the card, visits Customize, or leaves the welcome screen with nothing
/// on. The new-version notice: shown to every install until the user confirms hiding it.
@MainActor
@Observable
final class OnboardingStore {
    private static let customizeHintPendingKey = "openusage.onboarding.customizeHintPending"
    private static let newVersionNoticeDismissedKey = "openusage.notices.newVersionDismissed"

    private(set) var isCustomizeHintPending: Bool
    private(set) var isNewVersionNoticeDismissed: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isCustomizeHintPending = defaults.bool(forKey: Self.customizeHintPendingKey)
        self.isNewVersionNoticeDismissed = defaults.bool(forKey: Self.newVersionNoticeDismissedKey)
    }

    func dismissNewVersionNotice() {
        guard !isNewVersionNoticeDismissed else { return }
        isNewVersionNoticeDismissed = true
        defaults.set(true, forKey: Self.newVersionNoticeDismissedKey)
    }

    func markCustomizeHintPending() {
        guard !isCustomizeHintPending else { return }
        isCustomizeHintPending = true
        defaults.set(true, forKey: Self.customizeHintPendingKey)
    }

    func dismissCustomizeHint() {
        guard isCustomizeHintPending else { return }
        isCustomizeHintPending = false
        defaults.set(false, forKey: Self.customizeHintPendingKey)
    }
}
