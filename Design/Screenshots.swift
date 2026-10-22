// Renders README screenshots from made-up demo data (no real usage is read).
// Run through Design/make_screenshots.sh.
import SwiftUI
import AppKit

// MARK: - Demo data

private func demoResult() -> Scanner.Result {
    let now = Date()
    let cal = Calendar.current
    // Typical daily volume per agent (tokens, cache reads included) and its models.
    let plan: [(Agent, Double, [(String, Double)])] = [
        (.claude, 62e6, [("claude-opus-4-5", 0.8), ("claude-haiku-4-5", 0.2)]),
        (.codex, 24e6, [("gpt-5-codex", 1.0)]),
        (.grok, 11e6, [("grok-code-fast-1", 1.0)]),
        (.gemini, 6e6, [("gemini-2.5-pro", 1.0)]),
        (.copilot, 3e6, [("gpt-4.1", 1.0)]),
    ]
    var events: [UsageEvent] = []
    for day in 0..<30 {
        guard let dayStart = cal.date(byAdding: .day, value: -day, to: cal.startOfDay(for: now)) else { continue }
        for (i, (agent, base, models)) in plan.enumerated() {
            // Smooth, repeatable ups and downs; Copilot and Gemini skip some days.
            let wave = 0.55 + 0.45 * sin(Double(day) * 0.9 + Double(i) * 1.7) + 0.25 * cos(Double(day) * 0.37)
            if (agent == .copilot && day % 3 != 0) || (agent == .gemini && day % 2 == 1) { continue }
            let total = base * max(0.15, wave)
            for (model, share) in models {
                let perModel = total * share
                for k in 0..<12 {
                    let n = perModel / 12
                    var t = dayStart.addingTimeInterval(Double(9 + k) * 3600 + Double(i) * 300)
                    if t > now { t = now.addingTimeInterval(-Double(12 - k) * 240 - Double(i) * 60) }
                    events.append(UsageEvent(agent: agent, model: model, date: t,
                                             input: Int(n * 0.03), output: Int(n * 0.04),
                                             cacheRead: Int(n * 0.85), cacheWrite: Int(n * 0.08), key: nil))
                }
            }
        }
    }
    let h = 3600.0
    let quotas: [Agent: AgentQuota] = [
        .claude: AgentQuota(windows: [
            QuotaWindow(name: "5-hour", percent: 46, detail: nil, resetsAt: now + 2 * h + 600),
            QuotaWindow(name: "Weekly", percent: 63, detail: nil, resetsAt: now + 76 * h),
        ], asOf: now, note: nil),
        .codex: AgentQuota(windows: [
            QuotaWindow(name: "5-hour", percent: 28, detail: nil, resetsAt: now + 3 * h + 300),
            QuotaWindow(name: "Weekly", percent: 84, detail: nil, resetsAt: now + 122 * h),
        ], asOf: now, note: nil),
        .copilot: AgentQuota(windows: [
            QuotaWindow(name: "Premium", percent: 37, detail: "112 of 300", resetsAt: now + 220 * h),
        ], asOf: now, note: nil),
    ]
    return Scanner.Result(events: events, present: Set(Agent.allCases), quotas: quotas)
}

// MARK: - Rendering

/// Draws a view through AppKit (so native controls render) at the screen's scale.
@MainActor private func shot<V: View>(_ view: V, _ path: String) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 10, height: 10),
                       styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.isOpaque = false
    win.backgroundColor = .clear
    win.contentView = host
    let size = host.fittingSize
    win.setContentSize(size)
    host.frame = NSRect(origin: .zero, size: size)
    win.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    win.orderOut(nil)
    print("Wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

/// A floating panel look: rounded window background with a soft shadow.
private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .padding(28)
    }
}

/// A minimal window title bar: traffic lights and a centred title.
private struct WindowChrome<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in
                        Circle().fill(Color(red: Double(c >> 16 & 0xFF) / 255, green: Double(c >> 8 & 0xFF) / 255,
                                            blue: Double(c & 0xFF) / 255)).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            content.frame(width: 460)
        }
    }
}

@main
enum Screenshots {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)

        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let d = UserDefaults.standard
        for (k, v) in ["showInactive": false, "includeCacheReads": true, "detailBreakdown": true,
                       "detailChart": true, "detailModels": true, "quotaAlerts": true,
                       "claudeLiveQuota": true, "claudeAutoRenew": true] as [String: Any] {
            d.set(v, forKey: k)
        }
        d.set(14, forKey: "chartDays")
        d.set(300, forKey: "copilotAllowance")
        d.set("peakQuota", forKey: "menuBarShows")
        d.set("", forKey: "hiddenAgents")
        d.set(1, forKey: "refreshMinutes")

        let store = UsageStore(snapshot: demoResult())

        d.set("", forKey: "detailAgent")
        shot(Panel { ContentView().environmentObject(store) }, out + "/menu.png")

        d.set("all", forKey: "detailAgent")
        d.set(Period.week.rawValue, forKey: "period")
        shot(Panel { ContentView().environmentObject(store) }, out + "/menu-details.png")

        // Panes under a plain title bar (the tab strip does not render offscreen).
        shot(Panel { WindowChrome(title: "General") { GeneralPane() }.environmentObject(store) },
             out + "/preferences-general.png")
        shot(Panel { WindowChrome(title: "Display") { DisplayPane() }.environmentObject(store) },
             out + "/preferences-display.png")
        shot(Panel { WindowChrome(title: "Agents") { AgentsPane() }.environmentObject(store) },
             out + "/preferences-agents.png")
    }
}
