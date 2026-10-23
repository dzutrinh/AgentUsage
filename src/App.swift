import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--renew-claude-login") {
            guard let creds = ClaudeCredentials.read() else { print("No Claude Code login in the Keychain."); exit(1) }
            let before = creds.expiresAt
            switch ClaudeTokenRenewer().renew(creds, force: true) {
            case .success(let c):
                let saved = ClaudeCredentials.read()?.accessToken == c.accessToken
                print("Renewed. Expiry \(before.map { "\($0)" } ?? "?") -> \(c.expiresAt.map { "\($0)" } ?? "?"); saved to Keychain: \(saved)")
                exit(saved ? 0 : 1)
            case .failure(let msg):
                print(msg); exit(1)
            }
        } else if CommandLine.arguments.contains("--report") {
            Report.run()
        } else {
            AgentUsageApp.main()
        }
    }
}

struct AgentUsageApp: App {
    @StateObject private var store = UsageStore()
    @AppStorage("includeCacheReads") private var includeCacheReads = true
    @AppStorage("menuBarShows") private var menuBarShows = "tokens"

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            Label(labelText, systemImage: "gauge.with.dots.needle.33percent")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView().environmentObject(store)
        }
    }

    private var labelText: String {
        // "quota:<agent>" shows that agent's highest window ("claudeQuota" is the old name).
        let choice = menuBarShows == "claudeQuota" ? "quota:" + Agent.claude.rawValue : menuBarShows
        if choice == "icon" { return "" }
        if choice == "peakQuota", let p = store.peakPercent { return "\(Int(p.rounded()))%" }
        if choice.hasPrefix("quota:"), let a = Agent(rawValue: String(choice.dropFirst(6))),
           let p = store.peakPercent(a) {
            return "\(Int(p.rounded()))%"
        }
        return compact(store.todayTotal(includeCacheReads: includeCacheReads))
    }
}

/// `AgentUsage --report` prints the same numbers to the terminal (no menu bar).
enum Report {
    static func run() {
        let t0 = Date()
        let result = Scanner().scan()
        let secs = Date().timeIntervalSince(t0)
        print(String(format: "Scanned %d requests in %.2fs. Agents found: %@", result.events.count, secs,
                     Agent.allCases.filter { result.present.contains($0) }.map(\.rawValue).joined(separator: ", ")))
        for period in Period.allCases {
            let s = Summary(events: result.events, since: period.start())
            print("\n== \(period.label) ==")
            print(pad("agent", 13) + rpad("requests", 10) + rpad("input", 14) + rpad("output", 14)
                  + rpad("cache read", 16) + rpad("cache write", 14) + rpad("total", 16))
            for a in Agent.allCases {
                guard let t = s.byAgent[a] else { continue }
                print(row(a.rawValue, t))
            }
            print(row("ALL", s.overall))
        }
        print("\n== Quota ==")
        for a in Agent.allCases {
            guard let q = result.quotas[a] else { continue }
            let asOf = q.asOf.map { " (as of \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
            print("\(a.rawValue)\(asOf)")
            for w in q.windows {
                let v = w.percent.map { String(format: "%.0f%%", $0) } ?? ""
                print("  " + pad(w.name, 18) + rpad(v, 6) + "  " + (w.detail ?? "") + "  " + (resetText(w.resetsAt) ?? ""))
            }
            if let n = q.note { print("  note: \(n)") }
        }
        let s = Summary(events: result.events, since: nil)
        print("\n== Models (all time) ==")
        for m in s.byModel.prefix(15) {
            print(pad(m.agent.rawValue, 13) + pad(m.model, 32) + rpad(grouped(m.totals.total(includeCacheReads: true)), 18))
        }
    }

    private static func row(_ name: String, _ t: Totals) -> String {
        pad(name, 13) + rpad(grouped(t.requests), 10) + rpad(grouped(t.input), 14) + rpad(grouped(t.output), 14)
            + rpad(grouped(t.cacheRead), 16) + rpad(grouped(t.cacheWrite), 14)
            + rpad(grouped(t.total(includeCacheReads: true)), 16)
    }
    private static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    private static func rpad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
}
