import SwiftUI

/// The one mark a conversation, project, or tab shows for its current state.
///
/// Color alone never carries the meaning: every case also has its own symbol
/// and its own hover description.
struct ConversationIndicatorView: View {
    let indicator: ConversationIndicator
    var spinnerTint: Color?

    var body: some View {
        content
            .frame(width: 12, height: 12)
    }

    @ViewBuilder
    private var content: some View {
        switch indicator {
        case .none:
            Color.clear
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(spinnerTint)
                .help("Working")
                .accessibilityLabel("Working")
        case .waiting:
            symbol("questionmark.circle.fill", size: 11, color: .orange)
                .help("Waiting for you")
                .accessibilityLabel("Waiting for you")
        case .finished:
            symbol("checkmark.circle.fill", size: 11, color: .green)
                .help("Finished")
                .accessibilityLabel("Finished")
        case .failed:
            symbol("exclamationmark.circle.fill", size: 11, color: .red)
                .help("Failed")
                .accessibilityLabel("Failed")
        case .completed:
            symbol("checkmark.circle", size: 11, color: .secondary)
                .opacity(0.6)
                .help("Session closed")
                .accessibilityLabel("Session closed")
        case .dormant:
            symbol("moon.zzz.fill", size: 10, color: .secondary)
                .opacity(0.5)
                .help("Dormant")
                .accessibilityLabel("Dormant")
        }
    }

    private func symbol(
        _ name: String,
        size: CGFloat,
        color: Color
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size))
            .foregroundStyle(color)
    }
}
