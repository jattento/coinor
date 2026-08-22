import SwiftUI

/// Read-only live preview of one ego lite Browser Mirror tab: the most
/// recently polled screenshot plus a compact status bar. There is no
/// terminal surface or keyboard input here — "taking over" the Task Space
/// still happens inside ego lite itself.
@MainActor
struct BrowserMirrorView: View {
    @ObservedObject var tab: BrowserMirrorTab

    @State private var isActivatingEgoLite = false

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let image = tab.image {
                // Fills the tab and crops rather than letterboxing: the
                // captured screenshot's aspect ratio (ego lite's own window
                // size) rarely matches this tab's, and a visible black
                // letterbox band reads as "broken" even though it is only
                // ever a display artifact — the agent never sees this view,
                // it reads the real page through ego-browser's own tools.
                // Top-aligned so a crop trims the bottom of the page, never
                // its header/title.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .accessibilityIdentifier("browser-mirror.image.\(tab.id)")
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(placeholderText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .overlay(alignment: .bottom) { statusBar }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-mirror.\(tab.id)")
    }

    private var placeholderText: String {
        switch tab.state {
        case .unavailable(let reason):
            reason
        default:
            "Connecting to ego lite\u{2026}"
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            statusBadge
            if let title = tab.pageTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let url = tab.pageURL {
                Text(url)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            openInEgoLiteButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private var openInEgoLiteButton: some View {
        Button {
            guard !isActivatingEgoLite else { return }
            isActivatingEgoLite = true
            Task {
                await EgoLiteActivator.open(taskSpaceName: tab.taskSpaceName)
                isActivatingEgoLite = false
            }
        } label: {
            Label("Open in ego lite", systemImage: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .disabled(isActivatingEgoLite)
        .help("Bring this Task Space to the front in ego lite")
        .accessibilityIdentifier("browser-mirror.open-in-ego-lite.\(tab.id)")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch tab.state {
        case .connecting:
            badge("Connecting", systemImage: "circle.dotted", color: .secondary)
        case .live:
            badge("Live", systemImage: "circle.fill", color: .green)
        case .finished:
            badge("Done", systemImage: "checkmark.circle.fill", color: .secondary)
        case .closed:
            badge("Closed", systemImage: "xmark.circle.fill", color: .secondary)
        case .unavailable:
            badge(
                "Unavailable",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        }
    }

    private func badge(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
