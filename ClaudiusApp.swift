import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Data

struct CLIOutput: Decodable {
    let available: Bool
    let token_status: String
    let windows: [CLIWindow]
}

struct CLIWindow: Decodable {
    let name: String
    let percent: Double?
    let left: Double?
    let resets_in_seconds: Int?
    let blocked: Bool
}

/// Severity of being off a healthy burn rate. Higher wins when combining windows.
enum PaceLevel: Int, Comparable {
    case ok = 0       // green
    case mild = 1     // yellow
    case warn = 2     // orange
    case high = 3     // red
    static func < (a: PaceLevel, b: PaceLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Which way you're off pace — drives the direction arrow on each bar.
enum PaceDirection { case onTrack, tooSlow, tooFast }

struct UsageWindow: Identifiable {
    let name: String
    let percent: Double?
    let left: Double?
    let resetDate: Date?
    let blocked: Bool
    var id: String { name }

    /// Full length of this window: 5h for the session, 7d for weekly/model windows.
    var duration: TimeInterval { name == "session" ? 5 * 3600 : 7 * 24 * 3600 }

    /// Fraction of the window elapsed (0…1).
    var elapsedFraction: Double {
        guard let reset = resetDate else { return 1 }
        return max(0.02, min(1, 1 - reset.timeIntervalSinceNow / duration))
    }

    /// Projected final usage if the current average rate holds to the reset.
    /// 1.0 = on track to use it all exactly; >1 = you'll hit the cap early.
    var projectedFinal: Double? {
        guard resetDate != nil else { return nil }
        return (percent ?? 0) / 100 / elapsedFraction
    }

    /// How much quota you're projected to waste, weighted by how locked-in it is
    /// (near the reset). 0 when on track or over-pacing.
    private var wasteSeverity: Double {
        guard let p = projectedFinal, p < 1 else { return 0 }
        return (1 - p) * elapsedFraction
    }

    var direction: PaceDirection {
        if blocked { return .tooFast }
        guard let p = projectedFinal else { return .onTrack }
        if p >= 1.10 { return .tooFast }
        if wasteSeverity >= 0.10 { return .tooSlow }
        return .onTrack
    }

    /// PRIMARY color: mostly driven by burning too SLOW (wasting quota). Burning
    /// too fast only escalates color once you're genuinely about to run out —
    /// otherwise it shows as a minor ↑ arrow, not a hot color.
    var level: PaceLevel {
        if blocked { return .high }
        if wasteSeverity >= 0.33 { return .high }
        if wasteSeverity >= 0.20 { return .warn }
        if wasteSeverity >= 0.10 { return .mild }
        if let p = projectedFinal {
            if p >= 1.5 { return .warn }
            if p >= 1.10 { return .mild }
        }
        return .ok
    }

    var burningFast: Bool { direction == .tooFast }

    var color: Color {
        switch level {
        case .high: return .red
        case .warn: return .orange
        case .mild: return .yellow
        case .ok: return .green
        }
    }

    /// Urgency (0 green · 1 yellow · 2 orange · 3 red): starts from how much is
    /// left, then adjusts for time-to-reset — eases when reset is imminent (relief
    /// is coming) and escalates when you're on track to run out before it resets.
    var urgencyLevel: Int {
        if blocked { return 3 }
        let q = (left ?? percent.map { 100 - $0 } ?? 100) / 100   // quota-left fraction
        let elapsed = elapsedFraction
        let t = 1 - elapsed                                        // time-left fraction
        var level = q < 0.10 ? 3 : (q < 0.25 ? 2 : (q < 0.50 ? 1 : 0))   // magnitude base
        if elapsed > 0.1 {                                         // escalate: will you run out early?
            let projected = (1 - q) / elapsed
            if projected >= 1.5 { level = min(3, level + 2) }      // way ahead — locked out a while
            else if projected >= 1.0 { level = min(3, level + 1) } // on track to run out before reset
        }
        if t < 0.1 { level = max(0, level - 1) }                   // ease: reset is imminent
        return level
    }

    /// Fill color from urgency (same scale used by the menu-bar badges).
    var fillColor: Color {
        switch urgencyLevel {
        case 0: return .green
        case 1: return .yellow
        case 2: return .orange
        default: return .red
        }
    }

    /// Small direction glyph for the bar / menu. nil when on track.
    var arrow: String? {
        switch direction {
        case .tooFast: return "↑"
        case .tooSlow: return "↓"
        case .onTrack: return nil
        }
    }

    /// Pace glyph shown next to the name. Two different systems:
    ///  • Session (5h): a burn projection — "will I run out before it resets?".
    ///    ↑ orange/red when front-loading; nothing while coasting (no ↓, since
    ///    under-using a 5h window just resets).
    ///  • Weekly / Fable: even-pacing on the 20%/day budget — ↑ ahead, ↓ behind,
    ///    • on pace.
    var paceSpec: (glyph: String, color: Color)? {
        guard let used = percent else { return nil }
        if name == "session" {
            guard elapsedFraction >= 0.1 else { return nil }   // too early to project
            let projected = used / elapsedFraction
            if projected >= 100 { return ("↑", .red) }
            if projected >= 80 { return ("↑", .orange) }
            return nil
        }
        let perDay = used / max(0.5, elapsedFraction * 7)
        if perDay > 30 { return ("↑", .red) }
        if perDay > 20 { return ("↑", .orange) }
        if perDay < 10 { return ("↓", .blue) }
        return ("•", .secondary)
    }

    /// The on-pace corridor as bar fractions: below `lower` you're behind (↓),
    /// above `upper` you're ahead (↑). Slides right as the week elapses. nil for
    /// the session (which shows the fixed color ticks instead).
    var paceCorridor: (lower: Double, upper: Double)? {
        guard name != "session" else { return nil }
        let days = max(0.5, elapsedFraction * 7)
        return (min(1, 0.10 * days), min(1, 0.20 * days))
    }
}

enum FetchResult {
    case success(CLIOutput)
    case failure(String)
}

/// Result of an anchor probe. `.failed` is retryable (network/probe error);
/// `.skipped` (window already open / guard) and `.sent` are terminal.
enum AnchorOutcome { case sent, skipped, failed }

final class UsageModel: ObservableObject {
    @Published var windows: [UsageWindow] = []
    @Published var available: Bool?
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var isFetching = false
    @Published var isProbing = false
    @Published var probeResult: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var autoAnchor = (UserDefaults.standard.object(forKey: "autoAnchor") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoAnchor, forKey: "autoAnchor")
            scheduleAutoAnchor()
        }
    }
    /// Seconds after a window's reset to fire the next anchor.
    private let anchorDelayAfterReset: TimeInterval = 60

    private var timer: Timer?
    private var anchorTimer: Timer?
    private var anchorRetryTimer: Timer?
    private var anchorRetries = 0
    private let maxAnchorRetries = 6
    private var autoAnchorInFlight = false
    private static let cliPath = NSHomeDirectory() + "/.local/bin/claude-usage"

    init() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        // Refresh and re-evaluate anchoring the moment the machine wakes — timers
        // don't fire during sleep, so this is our catch-up on return.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// On wake: refresh, and if auto-anchor is on but no window is currently open
    /// (e.g. we slept through a reset), open one now so a fresh window is rolling
    /// when you return. The CLI's 30-min guard keeps repeated wakes from spamming.
    private func handleWake() {
        fetch()
        if autoAnchor && openSessionWindow == nil { maybeAutoAnchor() }
    }

    /// The window driving the menu-bar signal — the most off-pace one.
    var menuWindow: UsageWindow? {
        windows.max(by: { $0.level < $1.level })
    }

    /// A colored dot guarantees a visible signal (menu-bar SF Symbols often render
    /// monochrome). 🟢 on track · 🟡 mild · 🟠 off pace · 🔴 far off.
    var menuEmoji: String {
        guard let w = menuWindow else { return error == nil ? "⚪️" : "❔" }
        switch w.level {
        case .high: return "🔴"
        case .warn: return "🟠"
        case .mild: return "🟡"
        case .ok: return "🟢"
        }
    }

    /// Direction arrow for the menu bar — same glyph shown on the driving window's
    /// bar. ↑ burning too fast · ↓ burning too slow · "" on track.
    var menuArrow: String { menuWindow?.arrow ?? "" }

    /// Least "% left" across windows — the binding constraint. Stays visible even
    /// when the latest fetch failed, so a transient error no longer blanks the bar.
    var menuPercentText: String {
        guard let minLeft = windows.compactMap({ $0.left }).min() else { return "–" }
        return "\(Int(minLeft.rounded()))%"
    }

    // --- Menu bar icon: session circle + weekly circle + weekly-pace arrow ---

    private var sessionWindow: UsageWindow? { windows.first { $0.name == "session" } }
    private var weeklyWindow: UsageWindow? { windows.first { $0.name == "weekly" } }

    private func leftPercent(_ w: UsageWindow) -> Double? { w.left ?? w.percent.map { 100 - $0 } }

    /// Circle fill + inside-number color, from the same urgency scale as the bars
    /// (magnitude adjusted for time-to-reset).
    private func circleColors(_ w: UsageWindow?) -> (fill: NSColor, text: NSColor) {
        guard let w else { return (.systemGray, .white) }
        switch w.urgencyLevel {
        case 0: return (.systemGreen, .white)
        case 1: return (.systemYellow, .black)   // white reads poorly on bright yellow
        case 2: return (.systemOrange, .white)
        default: return (.systemRed, .white)
        }
    }

    /// The % left drawn inside a circle ("–" when the window is absent).
    private func circleLabel(_ w: UsageWindow?) -> String {
        guard let w, let l = leftPercent(w) else { return "–" }
        return String(Int(l.rounded()))
    }

    /// Weekly-pace arrow on a generous 20%/day budget (≈140%/week, room for heavy
    /// days). One arrow shape; color carries the severity:
    ///   ↑ red    = way over (>30%/day) — heading to blow the weekly limit
    ///   ↑ orange = over budget (>20%/day)
    ///   (none)   = within a healthy 10–20%/day band
    ///   ↓ blue   = well behind (<10%/day) — weekly headroom going unused
    private var weeklyArrowSpec: (glyph: String, color: NSColor)? {
        guard let w = weeklyWindow, let used = w.percent else { return nil }
        let perDay = used / max(0.5, w.elapsedFraction * 7)
        if perDay > 30 { return ("↑", .systemRed) }
        if perDay > 20 { return ("↑", .systemOrange) }
        if perDay < 10 { return ("↓", .systemBlue) }
        return nil
    }

    /// Draws a filled circle (diameter d) at x, with the window's % left inside.
    /// Draws a session (circle) or weekly (rounded square) badge with % left inside,
    /// so the two are distinguishable at a glance.
    private func drawCircle(_ w: UsageWindow?, at x: CGFloat, d: CGFloat, rounded: Bool) {
        let (fill, textColor) = circleColors(w)
        fill.setFill()
        let rect = NSRect(x: x + 2, y: 2, width: d - 4, height: d - 4)
        (rounded ? NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                 : NSBezierPath(ovalIn: rect)).fill()
        let label = circleLabel(w)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.count > 2 ? 8 : 10, weight: .bold),
            .foregroundColor: textColor,
            .paragraphStyle: para,
        ]
        let ts = label.size(withAttributes: attrs)
        label.draw(in: NSRect(x: x, y: (d - ts.height) / 2, width: d, height: ts.height),
                   withAttributes: attrs)
    }

    /// Menu-bar icon: session circle (left) + weekly circle (right) + weekly-pace
    /// arrow. Non-template so the colors render.
    var menuBarImage: NSImage {
        let d: CGFloat = 22
        let gap: CGFloat = 3
        let arrow = weeklyArrowSpec
        var arrowAttrs: [NSAttributedString.Key: Any] = [:]
        var arrowSize = NSSize.zero
        if let a = arrow {
            arrowAttrs = [.font: NSFont.systemFont(ofSize: 12, weight: .heavy),
                          .foregroundColor: a.color]
            arrowSize = a.glyph.size(withAttributes: arrowAttrs)
        }
        let arrowW: CGFloat = arrow == nil ? 0 : arrowSize.width + 1
        let img = NSImage(size: NSSize(width: d + gap + d + arrowW, height: d))
        img.lockFocus()
        drawCircle(sessionWindow, at: 0, d: d, rounded: false)      // session = circle
        drawCircle(weeklyWindow, at: d + gap, d: d, rounded: true)  // weekly = rounded square
        if let a = arrow {
            a.glyph.draw(at: NSPoint(x: d + gap + d + 1, y: (d - arrowSize.height) / 2),
                         withAttributes: arrowAttrs)
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    func refreshIfStale() {
        if let t = updatedAt, Date().timeIntervalSince(t) < 45 { return }
        fetch()
    }

    func fetch() {
        guard !isFetching else { return }
        isFetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runCLI()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false
                switch result {
                case .success(let out):
                    let now = Date()
                    self.windows = out.windows.map {
                        UsageWindow(
                            name: $0.name,
                            percent: $0.percent,
                            left: $0.left,
                            resetDate: $0.resets_in_seconds.map { now.addingTimeInterval(Double($0)) },
                            blocked: $0.blocked)
                    }
                    self.available = out.available
                    self.updatedAt = now
                    self.error = nil
                    self.scheduleAutoAnchor()
                case .failure(let message):
                    self.error = message
                }
            }
        }
    }

    /// The currently open session window (present with a future reset), or nil.
    private var openSessionWindow: UsageWindow? {
        guard let s = windows.first(where: { $0.name == "session" }),
              let reset = s.resetDate, reset.timeIntervalSinceNow > 0,
              (s.percent ?? 0) > 0 else { return nil }
        return s
    }

    /// Schedule the next auto-anchor for 60s after the current window's reset —
    /// so windows chain back-to-back, anchored to the reset boundary rather than
    /// to when the toggle was flipped. Reschedules on every fetch as the reset
    /// time updates. Does nothing if no window is open (nothing to chain from);
    /// a new window there comes from real use or the Test request button.
    func scheduleAutoAnchor() {
        anchorTimer?.invalidate()
        anchorTimer = nil
        guard autoAnchor, let s = openSessionWindow, let reset = s.resetDate else { return }
        let fireAt = reset.addingTimeInterval(anchorDelayAfterReset)
        let delay = max(1, fireAt.timeIntervalSinceNow)
        anchorTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.maybeAutoAnchor()
        }
    }

    /// Fire the anchor probe (non-forced): the CLI re-checks authoritatively and
    /// applies its own 30-min guard, so at most one probe goes out per window.
    /// On a genuine failure (network/probe) it retries with backoff; a skip or a
    /// success clears any pending retry.
    func maybeAutoAnchor() {
        guard autoAnchor, !autoAnchorInFlight, !isProbing else { return }
        autoAnchorInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (outcome, message) = Self.runAnchor(force: false)
            DispatchQueue.main.async {
                self.autoAnchorInFlight = false
                switch outcome {
                case .sent:
                    self.probeResult = "✓ auto: " + message
                    self.clearAnchorRetry()
                case .skipped:
                    self.clearAnchorRetry()
                case .failed:
                    self.scheduleAnchorRetry(reason: message)
                }
                self.fetch()
            }
        }
    }

    private func clearAnchorRetry() {
        anchorRetries = 0
        anchorRetryTimer?.invalidate()
        anchorRetryTimer = nil
    }

    /// Retry a failed anchor with exponential backoff (2, 4, 8, 15, 15… min),
    /// so a transient network drop doesn't cost you the whole window.
    private func scheduleAnchorRetry(reason: String) {
        anchorRetryTimer?.invalidate()
        guard autoAnchor, anchorRetries < maxAnchorRetries else { clearAnchorRetry(); return }
        anchorRetries += 1
        let delay = min(15 * 60, 60 * pow(2, Double(anchorRetries)))
        probeResult = "retrying anchor in \(Int(delay / 60))m (\(reason))"
        anchorRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.maybeAutoAnchor()
        }
    }

    /// Fire a tiny cheapest-model request to open a fresh 5-hour session window now.
    func sendTestRequest() {
        guard !isProbing else { return }
        isProbing = true
        probeResult = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (outcome, message) = Self.runAnchor(force: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProbing = false
                self.probeResult = (outcome == .sent ? "✓ " : "✗ ") + message
                self.fetch()  // reflect the new window immediately
            }
        }
    }

    private static func runAnchor(force: Bool) -> (AnchorOutcome, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = force ? ["anchor", "--force", "--json"] : ["anchor", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            return (.failed, "can't run claude-usage: \(error.localizedDescription)")
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + 200) == .timedOut {
            proc.terminate()
            return (.failed, "request timed out")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["status"] as? String {
            let msg = obj["message"] as? String ?? status
            switch status {
            case "sent": return (.sent, "window opened")
            case "skipped": return (.skipped, msg)
            default: return (.failed, msg)   // "error" — network/probe/usage failure
            }
        }
        let errText = (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.failed, errText.isEmpty ? "request failed (exit \(proc.terminationStatus))" : errText)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static func runCLI() -> FetchResult {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            return .failure("claude-usage not found at \(cliPath)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = ["--json", "--auto-refresh"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            return .failure("can't run claude-usage: \(error.localizedDescription)")
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + 240) == .timedOut {
            proc.terminate()
            return .failure("claude-usage timed out")
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        if let parsed = try? JSONDecoder().decode(CLIOutput.self, from: stdoutData) {
            return .success(parsed)
        }
        let message = (String(data: stderrData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(message.isEmpty ? "no usage data (exit \(proc.terminationStatus))" : message)
    }
}

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
        return Self.human(d.timeIntervalSinceNow)
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
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                        Text("Auto-anchor").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Keeps your 5-hour windows back-to-back. About a minute after each window resets, Claudius sends one tiny cheapest-model request so the next 5-hour window starts right away, instead of waiting until you next use Claude. Heavy users get more windows per day this way; if you rarely hit the 5-hour cap it does little. Off = a window only starts when you send your next message.")

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

@main
struct ClaudiusApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var pin = PinController()
    @StateObject private var sessions = SessionsModel()

    var body: some Scene {
        // Real window + Dock icon — open it from the Dock like any app.
        Window("Claude usage", id: "main") {
            PopoverView(model: model, pin: pin, sessions: sessions)
                .onAppear { pin.configure(model) }
        }
        .windowResizability(.contentSize)

        // Menu bar item stays, for the at-a-glance dot.
        MenuBarExtra {
            PopoverView(model: model, pin: pin, sessions: sessions)
                .onAppear { pin.configure(model) }
        } label: {
            MenuLabelView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
