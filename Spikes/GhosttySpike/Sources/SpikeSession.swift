import Combine
import SwiftUI

@MainActor
final class SpikeSession: ObservableObject {
    @Published private(set) var generation = 0

    let runtime: GhosttyRuntime
    let options: SpikeOptions
    let logger: SpikeLogger
    weak var surface: GhosttySurfaceView?

    init(runtime: GhosttyRuntime, options: SpikeOptions, logger: SpikeLogger) {
        self.runtime = runtime
        self.options = options
        self.logger = logger
    }

    func attach(_ surface: GhosttySurfaceView) {
        self.surface = surface
        logger.record("session_surface_attached generation=\(generation)")
    }

    func detach(_ surface: GhosttySurfaceView) {
        if self.surface === surface {
            self.surface = nil
        }
        logger.record("session_surface_detached generation=\(generation)")
    }

    func recreateSurface() {
        surface?.shutdown()
        surface = nil
        generation += 1
        logger.record("surface_recreate generation=\(generation)")
    }

    func shutdown() {
        surface?.shutdown()
        surface = nil
    }
}

@MainActor
struct GhosttySurfaceRepresentable: NSViewRepresentable {
    @ObservedObject var session: SpikeSession

    func makeNSView(context: Context) -> NSView {
        do {
            let view = try GhosttySurfaceView(
                runtime: session.runtime,
                options: session.options,
                logger: session.logger
            )
            view.onCloseRequest = {
                if session.options.automation {
                    session.logger.record("automation_host_close_received")
                } else {
                    NSApp.terminate(nil)
                }
            }
            session.attach(view)
            return view
        } catch {
            session.logger.record("surface_creation_failed error=\(error.localizedDescription)")
            return ErrorView(message: error.localizedDescription)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 900, height: 600))
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? GhosttySurfaceView)?.shutdown()
    }
}

private final class ErrorView: NSView {
    init(message: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: message)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
struct SpikeRootView: View {
    @ObservedObject var session: SpikeSession

    var body: some View {
        GhosttySurfaceRepresentable(session: session)
            .id(session.generation)
            .frame(minWidth: 480, minHeight: 320)
    }
}
