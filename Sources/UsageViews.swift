import SwiftUI
import AppKit

// MARK: - Views

struct MenuLabelView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        Image(nsImage: model.menuBarImage)
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color
    /// When set, draw the on-pace corridor (weekly) instead of the color ticks.
    var corridor: (lower: Double, upper: Double)? = nil
    /// Neutral reference marks at 50 / 75 / 90% used. Gray, not colored, because
    /// the fill color now tracks urgency (time-aware), not raw magnitude.
    private static let marks: [Double] = [0.5, 0.75, 0.9]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: max(4, w * min(1, max(0, fraction))))
                if let c = corridor {
                    // Faint "on-pace" band with two edge lines that slide right
                    // through the week. Fill past the right edge = ahead, short of
                    // the left edge = behind.
                    Rectangle().fill(Color.primary.opacity(0.10))
                        .frame(width: max(0, w * (c.upper - c.lower)))
                        .offset(x: w * c.lower)
                    ForEach([c.lower, c.upper], id: \.self) { p in
                        Rectangle().fill(Color.primary.opacity(0.6))
                            .frame(width: 1.5)
                            .position(x: w * p, y: 3.5)
                    }
                } else {
                    ForEach(Self.marks.indices, id: \.self) { i in
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 1)
                            .position(x: w * Self.marks[i], y: 3.5)
                    }
                }
            }
        }
        .frame(height: 7)
    }
}

struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name.capitalized).fontWeight(.medium)
                if let pace = window.paceSpec {
                    Text(pace.glyph).fontWeight(.bold).foregroundStyle(pace.color)
                }
                Spacer()
                Text(resetText).font(.caption).foregroundStyle(.secondary)
            }
            UsageBar(fraction: (window.percent ?? 0) / 100, color: window.fillColor,
                     corridor: window.paceCorridor)
            HStack {
                if window.blocked {
                    Text("LIMITED").font(.caption).bold().foregroundStyle(.red)
                }
                Text(usageText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var usageText: String {
        guard let left = window.left ?? window.percent.map({ 100 - $0 }) else { return "no data" }
        return "\(Int(left.rounded()))% left"
    }

    private var resetText: String {
        guard let d = window.resetDate else { return "" }
        return "\(Self.human(d.timeIntervalSinceNow)) · \(Self.clock(d))"
    }

    /// The absolute reset moment: clock time if it's within a day ("3:15 PM"),
    /// otherwise weekday + time ("Sat 8:00 AM") so multi-day windows are unambiguous.
    static func clock(_ d: Date) -> String {
        if d.timeIntervalSinceNow < 24 * 3600 {
            return d.formatted(date: .omitted, time: .shortened)
        }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func human(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        let d = s / 86_400
        let h = (s % 86_400) / 3_600
        let m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var pin: PinController
    @ObservedObject var sessions: SessionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude usage").font(.headline)
                Spacer()
                if let t = model.updatedAt {
                    Text("updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    pin.toggle()
                } label: {
                    Image(systemName: pin.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(pin.isPinned ? "Close the floating window" : "Keep on top in a floating window")
                Button {
                    model.fetch()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isFetching)
                .help("Refresh now")
            }

            if let error = model.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.needsSignIn {
                        Button("Sign in to Claude Code") { model.openSignIn() }
                            .controlSize(.small)
                            .help("Opens Terminal and runs `claude` so you can log in. "
                                  + "Claudius never sees your credentials.")
                    }
                }
            }

            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.windows) { WindowRow(window: $0) }
                }
            }

            SessionsSection(model: sessions)

            Divider()

            // One aligned row: the 5h-anchor feature (toggle + manual bolt) on the
            // left, app controls (login, quit) on the right.
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.autoAnchor },
                    set: { model.autoAnchor = $0 })) {
                        Text("Auto-refresh 5h limit").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Your 5-hour usage limit only starts counting once you send a message, then resets 5 hours later. With this on, about a minute after it resets Claudius sends one tiny cheapest-model request so a fresh 5-hour limit begins right away — instead of waiting until you next use Claude. Heavy users get more resets (and so more usage) per day; if you rarely hit the 5-hour limit it does little. Off = your 5-hour limit only starts when you send your next message.")

                Button {
                    model.sendTestRequest()
                } label: {
                    if model.isProbing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isProbing)
                .help("Anchor one now — fire a tiny request to open a fresh 5h window immediately")

                Spacer()

                Toggle(isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) })) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Launch Claudius at login")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit Claudius")
            }

            if let result = model.probeResult {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshIfStale() }
    }
}

// MARK: - Pinned floating window

/// A compact always-on-top panel showing the same bars, for keeping usage
/// visible without the popover auto-dismissing.
struct PinnedView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if model.windows.isEmpty {
                    Text(model.error ?? "loading…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.windows) { WindowRow(window: $0) }
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}

/// Owns the floating NSPanel. Toggled from the popover; also resets its own
/// state if the user closes the panel with its close button.
final class PinController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var isPinned = false
    private var panel: NSPanel?
    private weak var model: UsageModel?

    func configure(_ model: UsageModel) { self.model = model }

    func toggle() { isPinned ? unpin() : pin() }

    func pin() {
        guard panel == nil, let model else { return }
        let host = NSHostingController(rootView: PinnedView(model: model))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 180),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Claude usage"
        p.contentViewController = host
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Stay on the workspace where it was pinned — no .canJoinAllSpaces, so it
        // doesn't follow you across Spaces/AeroSpace workspaces. WM-agnostic.
        p.collectionBehavior = [.managed, .fullScreenAuxiliary]
        p.delegate = self
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
        isPinned = true
    }

    func unpin() {
        panel?.orderOut(nil)
        panel = nil
        isPinned = false
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        isPinned = false
    }
}
