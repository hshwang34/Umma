import SwiftUI
import UIKit

/// "Open Settings" for a denied camera, microphone or speech permission: the app can't ask
/// twice, so this goes to Umma's page in the Settings app.
struct OpenSettingsButton: View {
    static let title = "Open Settings"
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Button(Self.title) { openURL(url) }
                .font(SLFont.callout.weight(.semibold))
                .frame(minHeight: Metrics.minTapTarget)
                .accessibilityIdentifier("permission.openSettings")
        }
    }
}
