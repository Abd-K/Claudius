import SwiftUI

// MARK: - Data

struct CLIOutput: Decodable {
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
