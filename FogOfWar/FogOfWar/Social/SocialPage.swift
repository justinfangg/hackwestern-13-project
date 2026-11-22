import SwiftUI

/// First tab. Intentionally empty for now: a plain light page (MainView
/// rounds it to the screen's corners like the other tabs).
struct SocialPage: View {
    var body: some View {
        SideQuestDesign.profileSurface
            .ignoresSafeArea()
            .accessibilityLabel("Social")
    }
}
