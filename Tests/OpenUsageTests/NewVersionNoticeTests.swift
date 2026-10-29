import XCTest
@testable import OpenUsage

@MainActor
final class NewVersionNoticeTests: XCTestCase {
    func testNoticeShowsUntilDismissedAndStaysDismissedAcrossLaunches() {
        let suiteName = "OpenUsageTests.NewVersionNotice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = OnboardingStore(defaults: defaults)
        XCTAssertFalse(firstLaunch.isNewVersionNoticeDismissed, "every install starts with the notice showing")

        firstLaunch.dismissNewVersionNotice()
        XCTAssertTrue(firstLaunch.isNewVersionNoticeDismissed)

        let nextLaunch = OnboardingStore(defaults: defaults)
        XCTAssertTrue(nextLaunch.isNewVersionNoticeDismissed, "hiding the notice survives a relaunch")
    }
}
