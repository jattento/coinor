import SwiftUI

struct ConversationContentView: View {
    @ObservedObject var model: AppShellModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch coordinator.status {
            case .starting:
                StartupExperienceView(
                    state: .starting,
                    checks: model.startupChecks,
                    isRunningChecks: model.isRunningStartupChecks,
                    rerunChecks: {
                        Task {
                            await model.runStartupChecks()
                        }
                    }
                )
            case .failed(let message):
                StartupExperienceView(
                    state: .failed(message),
                    checks: model.startupChecks,
                    isRunningChecks: model.isRunningStartupChecks,
                    rerunChecks: {
                        Task {
                            await model.runStartupChecks()
                        }
                    },
                    retry: {
                        Task {
                            await coordinator.restart()
                        }
                    }
                )
            case .ready:
                if let runtimeManager = coordinator.runtimeManager {
                    RuntimeHostView(manager: runtimeManager)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.terminalRegion)
    }
}

private enum StartupExperienceState {
    case starting
    case failed(String)
}

private struct StartupExperienceView: View {
    let state: StartupExperienceState
    let checks: [StartupCheck]
    let isRunningChecks: Bool
    let rerunChecks: () -> Void
    var retry: (() -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    Spacer(minLength: 8)

                    ConanASCIIView()

                    status

                    StartupDiagnosticsPanel(
                        checks: checks,
                        isRunning: isRunningChecks,
                        presentation: .startup,
                        rerun: rerunChecks
                    )
                    .frame(maxWidth: 640)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height
                )
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .starting:
            VStack(spacing: 7) {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)

                    Text("Connecting to Grok")
                        .font(.system(size: 17, weight: .semibold))
                }

                Text(
                    "Conan is keeping watch while the local runtime comes online."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        case .failed(let message):
            VStack(spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 16, height: 16)

                    Text("Conan Code could not start")
                        .font(.system(size: 17, weight: .semibold))
                }

                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)

                if let retry {
                    Button(action: retry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 2)
                }
            }
        }
    }
}

/// The Conan mascot, also reused by `ActivityStackView`'s waiting screen.
struct ConanASCIIView: View {
    private static let art = #"""
                            ..,,,,,,,,,..
                     .,;%%%%%%%%%%%%%%%%%%%%;,.
                   %%%%%%%%%%%%%%%%%%%%////%%%%%%, .,;%%;,
            .,;%/,%%%%%/////%%%%%%%%%%%%%%////%%%%,%%//%%%,
        .,;%%%%/,%%%///%%%%%%%%%%%%%%%%%%%%%%%%%%%%,////%%%%;,
     .,%%%%%%//,%%%%%%%%%%%%%%%%@@%a%%%%%%%%%%%%%%%%,%%/%%%%%%%;,
   .,%//%%%%//,%%%%///////%%%%%%%@@@%%%%%%///////%%%%,%%//%%%%%%%%,
 ,%%%%%///%%//,%%//%%%%%///%%%%%@@@%%%%%////%%%%%%%%%,/%%%%%%%%%%%%%
.%%%%%%%%%////,%%%%%%%//%///%%%%@@@@%%%////%%/////%%%,/;%%%%%%%%/%%%
%/%%%%%%%/////,%%%%///%%////%%%@@@@@%%%///%%/%%%%%//%,////%%%%//%%%'
%//%%%%%//////,%/%a`  'a%///%%%@@@@@@%%////a`  'a%%%%,//%///%/%%%%%
%///%%%%%%///,%%%%@@aa@@%//%%%@@@@S@@@%%///@@aa@@%%%%%,/%////%%%%%
%%//%%%%%%%//,%%%%%///////%%%@S@@@@SS@@@%%/////%%%%%%%,%////%%%%%'
%%//%%%%%%%//,%%%%/////%%@%@SS@@@@@@@S@@@@%%%%/////%%%,////%%%%%'
`%/%%%%//%%//,%%%///%%%%@@@S@@@@@@@@@@@@@@@S%%%%////%%,///%%%%%'
  %%%%//%%%%/,%%%%%%%%@@@@@@@@@@@@@@@@@@@@@SS@%%%%%%%%,//%%%%%'
  `%%%//%%%%/,%%%%@%@@@@@@@@@@@@@@@@@@@@@@@@@S@@%%%%%,/////%%'
   `%%%//%%%/,%%%@@@SS@@SSs@@@@@@@@@@@@@sSS@@@@@@%%%,//%%//%'
    `%%%%%%/  %%S@@SS@@@@@Ss` .,,.    'sS@@@S@@@@%'  ///%/%'
      `%%%/    %SS@@@@SSS@@S.         .S@@SSS@@@@'    //%%'
               /`S@@@@@@SSSSSs,     ,sSSSSS@@@@@'
             %%//`@@@@@@@@@@@@@Ss,sS@@@@@@@@@@@'/
           %%%%@@00`@@@@@@@@@@@@@'@@@@@@@@@@@'//%%
       %%%%%%a%@@@@000aaaaaaaaa00a00aaaaaaa00%@%%%%%
    %%%%%%a%%@@@@@@@@@@000000000000000000@@@%@@%%%@%%%
 %%%%%%a%%@@@%@@@@@@@@@@@00000000000000@@@@@@@@@%@@%%@%%
%%%aa%@@@@@@@@@@@@@@0000000000000000000000@@@@@@@@%@@@%%%%
%%@@@@@@@@@@@@@@@00000000000000000000000000000@@@@@@@@@%%%%%
"""#

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: Self.art)
                .foregroundStyle(.primary)

            Text("CONAN")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .lineSpacing(0)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conan, the Coinor mascot")
    }
}
