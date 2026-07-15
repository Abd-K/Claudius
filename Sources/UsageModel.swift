import SwiftUI
import AppKit
import ServiceManagement

final class UsageModel: ObservableObject {
    @Published var windows: [UsageWindow] = []
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var isFetching = false
    @Published var isProbing = false
    @Published var probeResult: String?
    /// True when the Keychain token is missing or can't be revived — the one case
    /// that needs a human to log in.
    @Published var needsSignIn = false
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
    private var signInWatch: Timer?
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

    /// Draws one badge (diameter d) at x with the window's % left inside — an oval
    /// when `rounded` is false (session), a rounded square when true (weekly), so
    /// the two are distinguishable at a glance.
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
                    self.updatedAt = now
                    self.error = nil
                    self.needsSignIn = false
                    self.scheduleAutoAnchor()
                case .failure(let message):
                    self.error = Self.friendlyError(message)
                    self.needsSignIn = message.contains("signin_required")
                        || message.contains("no_credentials")
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
            case "sent": return (.sent, "5h limit refreshed")
            case "skipped": return (.skipped, msg)
            default: return (.failed, msg)   // "error" — network/probe/usage failure
            }
        }
        let errText = (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.failed, errText.isEmpty ? "request failed (exit \(proc.terminationStatus))" : errText)
    }

    /// Launch Claude Code's own login. Claudius never handles credentials itself —
    /// it runs `claude auth login` and lets Anthropic's flow do the work, then
    /// picks the new Keychain token up automatically.
    ///
    /// This goes through a generated .command file because `open -a Terminal <bin>`
    /// can't pass arguments — and dropping the user into a bare `claude` REPL, left
    /// to guess that they must type `/login`, is exactly the jarring part.
    func openSignIn() {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let claude = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            error = "Can't find the claude CLI — install Claude Code first"
            return
        }
        let dir = NSHomeDirectory() + "/Library/Application Support/Claudius"
        let script = dir + "/signin.command"
        let body = """
        #!/bin/zsh
        echo "Signing in to the Claude Code CLI (separate from the desktop app)…"
        echo
        "\(claude)" auth login
        echo
        echo "All done — close this window and go back to Claudius."
        """
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try body.write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        } catch {
            self.error = "Couldn't prepare sign-in: \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: script))
        watchForSignIn()
    }

    /// While the login is open, check every few seconds so the app flips back to
    /// live numbers the moment it succeeds, rather than sitting on a stale error
    /// for up to a full poll interval. Costs nothing: while signed out the CLI
    /// answers locally without touching the network.
    private func watchForSignIn() {
        signInWatch?.invalidate()
        var ticks = 0
        signInWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            ticks += 1
            if !self.needsSignIn || ticks > 60 {   // resolved, or give up after 5 min
                t.invalidate()
                self.signInWatch = nil
                return
            }
            self.fetch()
        }
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

    /// Turn a raw CLI error status into a short, human sentence for the popover.
    private static func friendlyError(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func number(after pattern: String) -> Int? {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(s[r].filter(\.isNumber))
        }
        if let secs = number(after: #"backing off \d+s"#) {
            let mins = max(1, Int((Double(secs) / 60).rounded()))
            return "Rate-limited by Anthropic — retrying in ~\(mins)m"
        }
        if s.contains("no_credentials") || s.contains("signin_required") {
            return "Claude Code CLI sign-in needed — separate from the desktop app"
        }
        if s.contains("stale_token") { return "Session token expired — refreshing…" }
        if let code = number(after: #"http_error_\d+"#) { return "Anthropic API error (\(code))" }
        if s.contains("timed out") { return "Request timed out — will retry" }
        if s.isEmpty { return "Couldn't read usage — will retry" }
        return s
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
