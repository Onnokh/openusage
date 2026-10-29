import AppKit
import SwiftUI

/// The warning at the very top of the dashboard that the next OpenUsage drops local spend and token
/// tracking and moves to in-app sign-in. Every install sees it until the user hides it, and hiding takes
/// a confirmation so a stray click on the close button can't make it vanish unread.
struct NewVersionNoticeCard: View {
    static let issueURL = URL(string: "https://github.com/robinebers/openusage/issues/1441")!

    @Environment(AppContainer.self) private var container
    @State private var isConfirmingDismiss = false

    var body: some View {
        DismissableHintCard(
            systemImage: "exclamationmark.triangle.fill",
            title: "A New OpenUsage Is Coming",
            message: "The next update removes spend and token tracking, with no transition period. You'll also sign in to each account inside the app.",
            buttonTitle: "Read What's Changing",
            tint: .orange,
            action: { NSWorkspace.shared.open(Self.issueURL) },
            onDismiss: { isConfirmingDismiss = true }
        )
        .alert("Hide This Notice?", isPresented: $isConfirmingDismiss) {
            Button("Hide Notice") {
                withAnimation(Motion.spring) { container.onboarding.dismissNewVersionNotice() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next update removes spend and token tracking for good. To keep them, stay on this version by turning off Check Automatically in Settings → Updates.")
        }
    }
}
