import SwiftUI

// MARK: - Model

/// A recent Claude Code session, as reported by `claude-usage sessions --json`.
/// Cache warmth is measured against a 1-hour window (the keep-alive target).
struct CacheSession: Identifiable, Decodable {
    let session_id: String
    let age_seconds: Int
    let name: String?
    let project: String?
    let branch: String?
    var scannedAt = Date()

    var id: String { session_id }
    /// The title Claude Code shows (custom /rename or derived), falling back to
    /// the project folder.
    var title: String { name ?? project ?? "session" }
    private enum CodingKeys: String, CodingKey { case session_id, age_seconds, name, project, branch }

    /// Seconds since last activity, advanced live between scans.
    var currentAge: TimeInterval { Double(age_seconds) + Date().timeIntervalSince(scannedAt) }
    /// Remaining fraction of the 1-hour cache window (1 = just used, 0 = expired).
    var warmFraction: Double { max(0, min(1, 1 - currentAge / 3600)) }
    var isWarm: Bool { currentAge < 3600 }
    var minutesLeft: Int { max(0, Int((3600 - currentAge) / 60)) }
}

private struct SessionsOutput: Decodable { let sessions: [CacheSession] }

/// Per-session consumption from `claude-usage cost --json`. cost_usd is the
/// API-equivalent (what pay-as-you-go would cost) — a subscriber doesn't pay it;
/// it's the fair cross-model weight for "which session ate the most".
struct CostSession: Identifiable, Decodable {
    let session_id: String
    let name: String?
    let cost_usd: Double
    let output_tokens: Int
    var id: String { session_id }
    var title: String { name ?? String(session_id.prefix(8)) }
}
private struct CostOutput: Decodable { let sessions: [CostSession]; let total_usd: Double }

final class SessionsModel: ObservableObject {
    @Published var sessions: [CacheSession] = []
    @Published var keepAliveIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "keepAliveIDs") ?? [])
    @Published var busyID: String?
    @Published var lastResult: String?
    @Published var costs: [CostSession] = []
    @Published var costsTotal: Double = 0
    @Published var showCosts = false
    @Published var costWindow = "1d"
    private var costsLoading = false

    private var timer: Timer?
    private let staleAfter = 3300  // 55 min — fire before the 1-hour cache lapses
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
            && s.isWarm && s.currentAge >= Double(staleAfter) {
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

    /// Consumption scan — heavier (reads full transcripts, cached), so only run
    /// it lazily when the user expands the section.
    func loadCosts() {
        guard !costsLoading else { return }
        costsLoading = true
        let window = costWindow
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.runCLI(["cost", "--json", "--since", window], timeout: 30)
            let out = data.flatMap { try? JSONDecoder().decode(CostOutput.self, from: $0) }
            DispatchQueue.main.async {
                if let out { self?.costs = out.sessions; self?.costsTotal = out.total_usd }
                self?.costsLoading = false
            }
        }
    }

    func setCostWindow(_ w: String) {
        guard w != costWindow else { return }
        costWindow = w
        costs = []; costsTotal = 0
        loadCosts()
    }

    private static func runKeepAlive(_ id: String, force: Bool) -> (String, String) {
        let stale = force ? "0" : "3300"
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

struct SessionsSection: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        if !model.sessions.isEmpty {
            Divider()
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Text("cache warmth").font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(spacing: 9) {
                    ForEach(model.sessions.prefix(5)) { SessionRow(session: $0, model: model) }
                }
            }
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

/// Ranked per-session consumption, most-consuming first, with a relative bar.
struct ConsumptionList: View {
    @ObservedObject var model: SessionsModel
    private let windows = ["5h", "1d", "1w", "all"]

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: Binding(get: { model.costWindow },
                                          set: { model.setCostWindow($0) })) {
                ForEach(windows, id: \.self) { w in Text(w == "all" ? "All" : w).tag(w) }
            }
            .pickerStyle(.segmented).controlSize(.mini).labelsHidden()

            if model.costs.isEmpty {
                Text("scanning transcripts…").font(.caption).foregroundStyle(.secondary)
            } else {
                let maxCost = model.costs.map(\.cost_usd).max() ?? 1
                let total = model.costsTotal
                VStack(spacing: 6) {
                    ForEach(model.costs.prefix(8)) { c in
                        CostRow(cost: c,
                                fraction: maxCost > 0 ? c.cost_usd / maxCost : 0,
                                share: total > 0 ? c.cost_usd / total : 0)
                    }
                }
                Text("share of your Claude usage · \(model.costWindow == "all" ? "all time" : "last " + model.costWindow)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
        }
    }
}

struct CostRow: View {
    let cost: CostSession
    let fraction: Double
    let share: Double  // 0…1 of total usage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(cost.title).font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text("\(Int((share * 100).rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
