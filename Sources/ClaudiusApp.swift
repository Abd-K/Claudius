import SwiftUI
import AppKit

@main
struct ClaudiusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = UsageModel()
    @StateObject private var pin = PinController()
    @StateObject private var sessions = SessionsModel()
    @StateObject private var dock = DockController.shared

    init() {
        let model = UsageModel()
        let pin = PinController()
        let sessions = SessionsModel()
        _model = StateObject(wrappedValue: model)
        _pin = StateObject(wrappedValue: pin)
        _sessions = StateObject(wrappedValue: sessions)
        pin.configure(model)
        // The window the Dock icon opens is built here so it exists at launch,
        // before any menu bar click has happened.
        DockController.shared.configure {
            PopoverView(model: model, pin: pin, sessions: sessions, dock: DockController.shared)
        }
    }

    var body: some Scene {
        // Menu bar is always present. The Dock icon and its window are optional —
        // see DockController and LSUIElement in Info.plist.
        MenuBarExtra {
            PopoverView(model: model, pin: pin, sessions: sessions, dock: dock)
                .onAppear { pin.configure(model) }
        } label: {
            MenuLabelView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Applies the saved Dock preference once AppKit has finished launching (doing it
/// earlier would be overwritten by LSUIElement), and reopens the window when the
/// user clicks the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockController.shared.apply()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockController.shared.showWindow()
        return true
    }
}

/// Owns the "Show in Dock" preference. Off (the default) the app is menu bar
/// only; on, it gets a Dock icon and a real window showing the same panel.
final class DockController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DockController()

    @Published var showInDock = UserDefaults.standard.bool(forKey: "showInDock") {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            apply()
        }
    }

    private var window: NSWindow?
    private var content: (() -> PopoverView)?

    func configure(_ content: @escaping () -> PopoverView) { self.content = content }

    func apply() {
        if showInDock {
            NSApp.setActivationPolicy(.regular)
            showWindow()
        } else {
            window?.orderOut(nil)
            window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func showWindow() {
        guard showInDock, let content else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Claude usage"
            w.contentViewController = NSHostingController(rootView: content())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
