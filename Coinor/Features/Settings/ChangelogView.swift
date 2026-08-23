import SwiftUI

/// The Changelog settings tab: every published Grok fork release, with the
/// fork's own features and fixes shown plainly and the features and fixes the
/// release pulled in from `xai-org/grok-build` highlighted with a yellow
/// background.
@MainActor
struct ChangelogView: View {
    @ObservedObject var model: ChangelogModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await model.load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Grok Changelog")
                .font(.headline)
            Spacer()
            if model.isLoaded {
                Text("\(model.entries.count) releases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoaded {
            if model.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No releases found")
                        .font(.title3)
                }
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(model.entries) { release in
                            releaseCard(release)
                        }
                    }
                    .padding(14)
                }
            }
        } else if let errorMessage = model.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Could not load the changelog")
                    .font(.title3)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Retry") {
                    Task { await model.load() }
                }
            }
            .padding(40)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("Loading the Grok changelog…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        }
    }

    private func releaseCard(_ release: GrokReleaseEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.tag)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(release.publishedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !release.forkSummary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fork")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(release.forkSummary, id: \.self) { item in
                        Text("• " + item)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }

            if !release.upstreamSummary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upstream (xAI)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                    ForEach(release.upstreamSummary, id: \.self) { item in
                        Text("• " + item)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.28))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        }
    }
}