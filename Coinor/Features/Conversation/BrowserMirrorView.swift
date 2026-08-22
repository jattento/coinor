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
                // Top-aligned rather than centered: any letterbox gap from
                // an aspect-ratio mismatch lands at the bottom, where the
                // status bar's material already covers it, instead of as a
                // bare gap above the page content.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
