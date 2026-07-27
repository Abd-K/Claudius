import AppKit
import SwiftUI

// MARK: - Model

/// A recent Claude Code session, as reported by `claude-usage sessions --json`.
/// Cache warmth is measured against a 1-hour window (the keep-alive target).
struct CacheSession: Identifiable, Decodable {
    let session_id: String
    let age_seconds: Int
    let name: String?
    let project: String?
    var scannedAt = Date()

    var id: String { session_id }
    /// The title Claude Code shows (custom /rename or derived), falling back to
    /// the project folder.
    var title: String { name ?? project ?? "session" }
    private enum CodingKeys: String, CodingKey { case session_id, age_seconds, name, project }

    /// Prompt-cache lifetime the keep-alive targets (mirrors CACHE_WARM_TTL in the CLI).
    static let warmTTL: TimeInterval = 3600

    /// Seconds since last activity, advanced live between scans.
    var currentAge: TimeInterval { age(at: Date()) }
    /// Age against a caller-supplied instant. Ordering a list needs this rather than
    /// `currentAge`: that re-reads the clock on every access, so two sessions of equal
    /// age can compare inconsistently and break the sort's ordering guarantee.
    func age(at now: Date) -> TimeInterval { Double(age_seconds) + now.timeIntervalSince(scannedAt) }
    /// Remaining fraction of the 1-hour cache window (1 = just used, 0 = expired).
    var warmFraction: Double { max(0, min(1, 1 - currentAge / Self.warmTTL)) }
    var isWarm: Bool { currentAge < Self.warmTTL }
    var minutesLeft: Int { max(0, Int((Self.warmTTL - currentAge) / 60)) }
}

private struct SessionsOutput: Decodable { let sessions: [CacheSession] }

/// Per-session consumption from `claude-usage cost --json`. cost_usd is the
/// API-equivalent (what pay-as-you-go would cost) — a subscriber doesn't pay it;
/// it's the fair cross-model weight for "which session ate the most".
struct CostSession: Identifiable, Decodable {
    let session_id: String
    let name: String?
    let cost_usd: Double
    /// Percentage *points* of the weekly limit this session accounts for (0…100),
    /// taken from the API's own reported utilisation rather than a guessed dollar
    /// allowance. nil when the session did no work inside the current week — it
    /// consumed none of it, however expensive it was at the time.
    let week_percent: Double?
    var id: String { session_id }
    var title: String { name ?? String(session_id.prefix(8)) }
}
/// The weekly share is per-session (`week_percent`), so there's no report-wide
/// denominator to carry here. The CLI also emits `baseline_usd` for its own text
/// output; the app has no use for it and leaves it undecoded.
private struct CostOutput: Decodable {
    let sessions: [CostSession]
    let total_usd: Double
}

final class SessionsModel: ObservableObject {
    @Published var sessions: [CacheSession] = []
    @Published var keepAliveIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "keepAliveIDs") ?? [])
    @Published var busyID: String?
    @Published var lastResult: String?
    @Published var costs: [CostSession] = []
    @Published var costsTotal: Double = 0
    @Published var showCosts = false
    @Published var showAllSessions = false
    @Published var costWindow = "1d"
    /// Drives the placeholder: a scan in progress, a finished scan (which may
    /// legitimately have found nothing), or one that failed outright.
    @Published private(set) var costsLoading = false
    @Published private(set) var costsLoaded = false
    @Published private(set) var costsFailed = false

    private var timer: Timer?
    private static let staleAfter = 3300  // 55 min — fire before the 1-hour cache lapses
    private static let cliPath = NSHomeDirectory() + "/.local/bin/claude-usage"

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.tickKeepAlive()
        }
    }

    func toggleKeepAlive(_ id: String) {
        if keepAliveIDs.contains(id) { keepAliveIDs.remove(id) } else { keepAliveIDs.insert(id) }
        UserDefaults.standard.set(Array(keepAliveIDs), forKey: "keepAliveIDs")
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = Self.runSessions()
            DispatchQueue.main.async { if let list { self?.sessions = list } }
        }
    }

    /// For each keep-alive-enabled session that's near expiry, send a stub. The
    /// CLI re-checks and skips anything still warm, so firing early is harmless.
    private func tickKeepAlive() {
        guard busyID == nil else { return }
        // Only extend sessions that are still warm and near expiry. Never warm a
        // cold one — the CLI refuses it too, but don't even spawn the attempt.
        for s in sessions where keepAliveIDs.contains(s.session_id)
            && s.isWarm && s.currentAge >= Double(Self.staleAfter) {
            sendKeepAlive(s.session_id, manual: false)
            break  // one at a time; the next tick catches the rest
        }
    }

    /// Manual = force (bypass the stale guard); auto = only if idle > staleAfter.
    func sendKeepAlive(_ id: String, manual: Bool) {
        guard busyID == nil else { return }
        busyID = id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, message) = Self.runKeepAlive(id, force: manual)
            DispatchQueue.main.async {
                self?.busyID = nil
                self?.lastResult = "\(status): \(message)"
                self?.refresh()
            }
        }
    }

    // MARK: CLI plumbing

    private static func runCLI(_ args: [String], timeout: TimeInterval) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        return out.fileHandleForReading.readDataToEndOfFile()
    }

    private static func runSessions() -> [CacheSession]? {
        guard let data = runCLI(["sessions", "--json", "--max-age", "7200"], timeout: 15) else { return nil }
        return (try? JSONDecoder().decode(SessionsOutput.self, from: data))?.sessions
    }

    /// Consumption scan — heavier than the session list (it reads transcripts, though
    /// they're cached), so it only runs when the section is open.
    ///
    /// One scan at a time. A request arriving mid-scan isn't dropped: the in-flight
    /// completion compares the window it fetched against the one now selected and
    /// re-fires if they differ. Dropping it instead left the list cleared by
    /// `setCostWindow` and never refilled — a permanent "scanning transcripts…".
    func loadCosts() {
        guard !costsLoading else { return }
        costsLoading = true
        costsFailed = false
        let window = costWindow
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.runCLI(["cost", "--json", "--since", window], timeout: 30)
            let out = data.flatMap { try? JSONDecoder().decode(CostOutput.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.costsLoading = false
                guard window == self.costWindow else {
                    self.loadCosts()   // moved on mid-scan — fetch what's wanted now
                    return
                }
                guard let out else {
                    self.costsFailed = true   // don't sit on a spinner that never resolves
                    return
                }
                self.costs = out.sessions
                self.costsTotal = out.total_usd
                self.costsLoaded = true
            }
        }
    }

    func setCostWindow(_ w: String) {
        guard w != costWindow else { return }
        costWindow = w
        costs = []; costsTotal = 0; costsLoaded = false
        loadCosts()
    }

    private static func runKeepAlive(_ id: String, force: Bool) -> (String, String) {
        let stale = force ? "0" : String(staleAfter)
        guard let data = runCLI(["keepalive", "--session-id", id, "--stale-after", stale, "--json"],
                                timeout: 200) else {
            return ("error", "couldn't run claude-usage")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["status"] as? String {
            return (status, (obj["message"] as? String) ?? status)
        }
        return ("error", "no response")
    }
}

// MARK: - Views

/// Thin fuel-gauge bar for cache warmth — no threshold ticks (those are a
/// magnitude concept; warmth is just "time left in the window").
private struct WarmthBar: View {
    let fraction: Double  // remaining warmth, 0…1
    let warm: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(warm ? Color.green : Color.gray)
                    .frame(width: max(3, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

private struct SessionRow: View {
    let session: CacheSession
    @ObservedObject var model: SessionsModel

    private var keepOn: Bool { model.keepAliveIDs.contains(session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button { model.toggleKeepAlive(session.id) } label: {
                    Image(systemName: keepOn ? "flame.fill" : "flame")
                        .foregroundStyle(keepOn ? Color.orange : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(keepOn ? "Keep-warm on — extends this session's cache near expiry (while it's still warm)"
                             : "Keep this session's cache warm")
                Button { model.sendKeepAlive(session.id, manual: true) } label: {
                    if model.busyID == session.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.busyID != nil || !session.isWarm)
                .help(session.isWarm
                      ? "Refresh now — re-reads this session's context to extend its live cache (uses quota)"
                      : "Cold — won't refresh; warming a dead cache is a full re-read for nothing")
            }
            WarmthBar(fraction: session.warmFraction, warm: session.isWarm)
            Text(session.isWarm ? "~\(session.minutesLeft)m left" : "expired")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Natural height of the session rows, so the expanded scroll view can be given a
/// definite height instead of guessing a per-row size (which breaks at larger
/// accessibility text sizes).
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SessionsSection: View {
    @ObservedObject var model: SessionsModel
    @State private var listHeight: CGFloat = 0

    /// Rows shown before the list has to be expanded.
    private static let collapsed = 5
    /// Tallest the expanded list gets before it scrolls instead of growing the popover.
    /// Scaled to the display: a fixed cap is either too short to reveal anything beyond
    /// the collapsed five (which reads as the button doing nothing) or tall enough to
    /// push the popover off a laptop screen.
    private static var expandedMaxHeight: CGFloat {
        let usable = NSScreen.main?.visibleFrame.height ?? 800
        return min(560, max(300, usable * 0.45))
    }

    /// Warm sessions first, the nearest to going cold at the top — those are the only
    /// ones you can still act on, most urgent first. Expired sessions sink below (a
    /// dead cache can't be extended, and the refresh button is disabled for them),
    /// most recently expired first so the freshest history stays nearest.
    private func ordered(at now: Date) -> [CacheSession] {
        model.sessions.sorted { a, b in
            let (aAge, bAge) = (a.age(at: now), b.age(at: now))
            let (aWarm, bWarm) = (aAge < CacheSession.warmTTL, bAge < CacheSession.warmTTL)
            if aWarm != bWarm { return aWarm }
            return aWarm ? aAge > bAge : aAge < bAge
        }
    }

    var body: some View {
        if !model.sessions.isEmpty {
            Divider()
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Text("nearest to expiry").font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let all = ordered(at: ctx.date)
                let shown = model.showAllSessions ? all : Array(all.prefix(Self.collapsed))
                let rows = VStack(spacing: 9) {
                    ForEach(shown) { SessionRow(session: $0, model: model) }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                })
                // Expanded, the list scrolls rather than growing the popover, which has
                // no scroll view of its own. The frame must be a *definite* height: a
                // ScrollView has no intrinsic height, so a bare maxHeight collapses it to
                // nothing and expanding looks like it hid the list. Fall back to the cap
                // until the first measurement lands.
                if model.showAllSessions {
                    ScrollView {
                        rows.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(listHeight > 0 ? listHeight : Self.expandedMaxHeight,
                                       Self.expandedMaxHeight))
                } else {
                    rows
                }
                if all.count > Self.collapsed {
                    Button { model.showAllSessions.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.showAllSessions ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                            Text(model.showAllSessions
                                 ? "Show fewer"
                                 : "Show all \(all.count) · \(all.count - Self.collapsed) hidden")
                                .font(.caption)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            if let r = model.lastResult {
                Text(r).font(.caption)
                    .foregroundStyle(r.hasPrefix("sent") || r.hasPrefix("skipped") ? Color.secondary : Color.orange)
                    .lineLimit(1).truncationMode(.tail)
            }

            Button {
                model.showCosts.toggle()
                if model.showCosts { model.loadCosts() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.showCosts ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text(model.showCosts ? "Hide consumption" : "Show consumption")
                        .font(.caption)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if model.showCosts { ConsumptionList(model: model) }
        }
    }
}

/// Ranked per-session consumption, most-consuming first. Rows are measured against
/// fixed yardsticks (a typical session, the weekly allowance) rather than a share of
/// the window: a share is zero-sum, so it moves whenever an unrelated session runs,
/// reads differently in every window, and can't be compared across days.
struct ConsumptionList: View {
    @ObservedObject var model: SessionsModel
    private let windows = ["5h", "1d", "1w", "all"]

    private var windowLabel: String {
        model.costWindow == "all" ? "all time" : "last " + model.costWindow
    }

    /// Two scales, deliberately: the weekly share moves with the plan (promotions,
    /// tier changes) and answers "what did this cost me now"; the dollar is
    /// plan-independent and stays comparable across those changes.
    private var caption: String { "% of weekly limit · API-equivalent cost · \(windowLabel)" }

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: Binding(get: { model.costWindow },
                                          set: { model.setCostWindow($0) })) {
                ForEach(windows, id: \.self) { w in Text(w == "all" ? "All" : w).tag(w) }
            }
            .pickerStyle(.segmented).controlSize(.mini).labelsHidden()

            if model.costs.isEmpty {
                Text(model.costsLoading ? "scanning transcripts…"
                     : model.costsFailed ? "couldn't read consumption"
                     : model.costsLoaded ? "no sessions in this window"
                     : "scanning transcripts…")
                    .font(.caption)
                    .foregroundStyle(model.costsFailed ? Color.orange : Color.secondary)
            } else {
                let shown = Array(model.costs.prefix(8))
                let maxCost = shown.map(\.cost_usd).max() ?? 1
                VStack(spacing: 6) {
                    ForEach(shown) { c in
                        CostRow(cost: c,
                                weekPercent: c.week_percent,
                                fraction: maxCost > 0 ? c.cost_usd / maxCost : 0)
                    }
                }
                Text(caption)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
        }
    }
}

struct CostRow: View {
    let cost: CostSession
    let weekPercent: Double?  // percentage points (0…100) of the weekly limit
    let fraction: Double      // width relative to the heaviest row on screen

    /// Compact money — cents stop carrying information once it's past $10, and the
    /// row has three numbers competing for a 300pt-wide popover.
    private static func money(_ v: Double) -> String {
        v >= 10 ? "$\(Int(v.rounded()))" : String(format: "$%.2f", v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(cost.title).font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if let w = weekPercent, w >= 0.05 {
                    Text(String(format: "%.1f%% wk", w))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                // Dimmer than the weekly share: it's the stable cross-plan reference,
                // not the figure that tells you what a session actually cost you today.
                Text(Self.money(cost.cost_usd))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, g.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
    }
}
