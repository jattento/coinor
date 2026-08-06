import AppKit
import SwiftUI

@MainActor
final class SpikeApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: SpikeOptions
    private let logger: SpikeLogger
    private var runtime: GhosttyRuntime?
    private var session: SpikeSession?
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(options: SpikeOptions, logger: SpikeLogger) {
        self.options = options
        self.logger = logger
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let resources = Bundle.main.resourceURL?
                .appendingPathComponent("ghostty", isDirectory: true).path else {
                throw SpikeError.missingResources("Bundle.main/Contents/Resources/ghostty")
            }
            let runtime = try GhosttyRuntime(
                resourcesDirectory: resources,
                initiallyFocused: NSApp.isActive,
                allowExternalURLRequests: !options.automation,
                logger: logger
            )
            let session = SpikeSession(runtime: runtime, options: options, logger: logger)
            self.runtime = runtime
            self.session = session

            let window = SpikeWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.spikeLogger = logger
            window.rejectAccessibilityFrameChanges = options.automation
            window.title = "Coinor GhosttyKit Spike"
            window.minSize = NSSize(width: 480, height: 320)
            window.isRestorable = false
            window.center()
            window.delegate = self
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 640))
            let hostingView = NSHostingView(rootView: SpikeRootView(session: session))
            hostingView.sizingOptions = []
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: container.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            window.contentView = container
            window.setContentSize(NSSize(width: 980, height: 640))
            window.makeKeyAndOrderFront(nil)
            self.window = window

            NSApp.activate(ignoringOtherApps: true)
            logger.record("app_started pid=\(ProcessInfo.processInfo.processIdentifier)")
            logger.record("window_id=\(window.windowNumber)")
            logger.record("finder_environment_path=\(ProcessInfo.processInfo.environment["PATH"] ?? "unset")")
            installObservers(runtime: runtime, session: session)

            if options.automation {
                scheduleAutomation(session: session, window: window)
            }
            if let exitAfter = options.exitAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + exitAfter) {
                    self.logger.record("scheduled_exit")
                    NSApp.terminate(nil)
                }
            }
        } catch {
            logger.record("startup_failed error=\(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Ghostty spike failed to start"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        window?.contentView = nil
        session?.shutdown()
        session = nil
        runtime?.shutdown()
        runtime = nil
        logger.record("app_terminated")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime?.setApplicationFocus(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        runtime?.setApplicationFocus(false)
    }

    func windowWillClose(_ notification: Notification) {
        logger.record("window_closed")
    }

    private func installObservers(runtime: GhosttyRuntime, session: SpikeSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                self.session?.surface?.updateOcclusion(
                    isVisible: window.occlusionState.contains(.visible)
                )
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.session?.surface?.updateOcclusion(isVisible: true)
                self?.session?.logger.record("workspace_wake")
            }
        })
    }

    private func scheduleAutomation(session: SpikeSession, window: NSWindow) {
        let command = "echo ok > .build/keyboard-marker.txt\n"
        let clipboardCommand = "echo clipboard > .build/clipboard-marker.txt"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            session.surface?.sendAutomationText(command)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard let surface = session.surface else { return }
            _ = surface.performAutomationAction("scroll_page_up")
            _ = surface.performAutomationAction("scroll_page_down")
            _ = surface.performAutomationAction("select_all")
            _ = surface.performAutomationAction("copy_to_clipboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                session.logger.record(
                    "clipboard_copy_contains_marker=\(copied.contains("Coinor GhosttyKit spike"))"
                )
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboardCommand, forType: .string)
            _ = session.surface?.performAutomationAction("paste_from_clipboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                session.surface?.sendAutomationText("\n")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            window.setContentSize(NSSize(width: 620, height: 380))
            session.logger.record("automation_resize=compact")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                session.logger.record(
                    "window_content_size_compact=\(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))"
                )
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            window.setContentSize(NSSize(width: 1080, height: 700))
            session.logger.record("automation_resize=wide")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                session.logger.record(
                    "window_content_size_wide=\(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))"
                )
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let visible = session.surface?.visibleText()
                .replacingOccurrences(of: "\n", with: "\\n") ?? ""
            session.logger.record("visible_text=\(visible.prefix(500))")
            session.surface?.performAutomationAction("new_window")
            session.surface?.performAutomationAction("new_tab")
            session.surface?.performAutomationAction("new_split:right")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let visibleWindows = NSApp.windows.filter(\.isVisible).count
                session.logger.record("visible_window_count_after_suppressed_actions=\(visibleWindows)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
            guard let surface = session.surface else { return }
            let urlHandled = session.runtime.exerciseOpenURLAction(
                surface: surface,
                url: "coinor-spike://phase0"
            )
            session.logger.record("automation_url_action handled=\(urlHandled)")
            let closeHandled = session.runtime.exerciseCloseAction(surface: surface)
            session.logger.record("automation_close_action handled=\(closeHandled)")
            surface.updateOcclusion(isVisible: false)
            surface.updateOcclusion(isVisible: true)
            surface.exerciseBackingPropertyTransition()
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didWakeNotification,
                object: nil
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) {
            session.recreateSurface()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) {
            session.recreateSurface()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            session.recreateSurface()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.4) {
            let visible = session.surface?.visibleText()
                .replacingOccurrences(of: "\n", with: "\\n") ?? ""
            session.logger.record("visible_text_after_recreate=\(visible.prefix(500))")
        }
    }

}
