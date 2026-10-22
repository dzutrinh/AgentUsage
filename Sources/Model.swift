import Foundation
import SwiftUI

enum Agent: String, CaseIterable, Identifiable, Sendable {
    case claude = "Claude Code"
    case codex = "Codex"
    case gemini = "Gemini CLI"
    case copilot = "Copilot CLI"
    case grok = "Grok"

    var id: String { rawValue }

    /// Vivid two-stop gradient per agent: [start, end].
    var gradientColors: [Color] {
        func c(_ hex: UInt32) -> Color {
            Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        switch self {
        case .claude: return [c(0xFF7A3D), c(0xFF2E7E)]   // tangerine -> hot pink
        case .codex: return [c(0x3BE38B), c(0x00B3C7)]    // spring green -> teal
        case .gemini: return [c(0x3D8BFF), c(0x8A4DFF)]   // azure -> violet
        case .copilot: return [c(0xC24DFF), c(0xFF4FD8)]  // purple -> magenta
        case .grok: return [c(0xFFD23F), c(0xFF8A00)]     // sun yellow -> amber
        }
    }

    var color: Color { gradientColors[1] }

    /// Diagonal fill for dots and swatches.
    var fill: LinearGradient {
        LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// One model request. Token fields never overlap: `input` excludes cached tokens,
/// `output` includes reasoning tokens.
struct UsageEvent: Sendable {
    var agent: Agent
    var model: String
    var date: Date
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    /// Same key = same request seen twice (resumed sessions, streamed lines).
    var key: String?

    var total: Int { input + output + cacheRead + cacheWrite }
}

struct Totals {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, requests = 0

    mutating func add(_ e: UsageEvent) {
        input += e.input; output += e.output
        cacheRead += e.cacheRead; cacheWrite += e.cacheWrite
        requests += 1
    }

    func total(includeCacheReads: Bool) -> Int {
        input + output + cacheWrite + (includeCacheReads ? cacheRead : 0)
    }
}

enum Period: String, CaseIterable, Identifiable {
    case fiveHours, today, week, month, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHours: return "5h"
        case .today: return "Today"
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        }
    }

    func start(now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        switch self {
        case .fiveHours: return now.addingTimeInterval(-5 * 3600)
        case .today: return today
        case .week: return cal.date(byAdding: .day, value: -6, to: today)
        case .month: return cal.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

struct ModelRow: Identifiable {
    let model: String
    let agent: Agent
    let totals: Totals
    var id: String { agent.rawValue + "/" + model }
}

struct Summary {
    var overall = Totals()
    var byAgent: [Agent: Totals] = [:]
    var byModel: [ModelRow] = []

    init(events: [UsageEvent], since: Date?) {
        var models: [String: (Agent, String, Totals)] = [:]
        for e in events {
            if let since, e.date < since { continue }
            overall.add(e)
            byAgent[e.agent, default: Totals()].add(e)
            let k = e.agent.rawValue + "/" + e.model
            var m = models[k] ?? (e.agent, e.model, Totals())
            m.2.add(e)
            models[k] = m
        }
        byModel = models.values
            .map { ModelRow(model: $0.1, agent: $0.0, totals: $0.2) }
            .sorted { $0.totals.total(includeCacheReads: true) > $1.totals.total(includeCacheReads: true) }
    }
}

struct DayPoint: Identifiable {
    let day: Date
    let agent: Agent
    let tokens: Int
    var id: String { "\(day.timeIntervalSince1970)-\(agent.rawValue)" }
}

func dailyPoints(_ events: [UsageEvent], days: Int, includeCacheReads: Bool) -> [DayPoint] {
    let cal = Calendar.current
    guard let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date())) else { return [] }
    var sums: [Date: [Agent: Int]] = [:]
    for e in events where e.date >= start {
        let d = cal.startOfDay(for: e.date)
        let n = e.input + e.output + e.cacheWrite + (includeCacheReads ? e.cacheRead : 0)
        sums[d, default: [:]][e.agent, default: 0] += n
    }
    var out: [DayPoint] = []
    for (d, byAgent) in sums {
        for (a, n) in byAgent { out.append(DayPoint(day: d, agent: a, tokens: n)) }
    }
    return out.sorted { $0.day < $1.day }
}

/// Keeps one event per key; when a request was logged more than once, keeps the largest copy.
func dedupe(_ events: [UsageEvent]) -> [UsageEvent] {
    var out: [UsageEvent] = []
    out.reserveCapacity(events.count)
    var index: [String: Int] = [:]
    for e in events {
        guard let k = e.key else { out.append(e); continue }
        if let i = index[k] {
            if e.total > out[i].total { out[i] = e }
        } else {
            index[k] = out.count
            out.append(e)
        }
    }
    return out
}

// MARK: - Formatting

func compact(_ n: Int) -> String {
    let d = Double(n)
    switch abs(d) {
    case 1e9...: return String(format: "%.1fB", d / 1e9)
    case 1e6...: return String(format: "%.1fM", d / 1e6)
    case 1e3...: return String(format: "%.1fK", d / 1e3)
    default: return "\(n)"
    }
}

func grouped(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
