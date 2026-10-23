import SwiftUI
import Charts

// The menu: a compact card per active agent (today's tokens + quota bars), then an
// optional detail section for one agent or all of them. Settings live in Preferences.

struct ContentView: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("includeCacheReads") private var includeCacheReads = true
    @AppStorage("showInactive") private var showInactive = false
    @AppStorage("hiddenAgents") private var hiddenAgents = ""
    @AppStorage("detailAgent") private var detailAgent = ""

    var body: some View {
        let today = Summary(events: store.events, since: Period.today.start())
        let agents = visibleAgents()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Agent Usage").font(.headline)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                iconButton("arrow.clockwise", help: "Refresh") { store.refresh(forceQuota: true) }
                iconButton("gearshape", help: "Preferences…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }

            if agents.isEmpty {
                Text(store.lastUpdated == nil ? "Reading logs…" : "No agent activity in the last 30 days.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(agents.enumerated()), id: \.element) { i, a in
                if i > 0 { Divider() }
                AgentCard(agent: a, today: today.byAgent[a], quota: store.quotas[a],
                          includeCacheReads: includeCacheReads,
                          selected: detailAgent == a.rawValue) {
                    detailAgent = detailAgent == a.rawValue ? "" : a.rawValue
                }
            }

            if let filter = detailFilter {
                Divider()
                DetailSection(agent: filter.agent, title: filter.title) { detailAgent = "" }
            }

            Divider()
            HStack {
                if let t = store.lastUpdated {
                    Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("About") { showAbout() }.controlSize(.small)
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { store.refresh(forceQuota: true) }
    }

    private func visibleAgents() -> [Agent] {
        let hidden = Set(hiddenAgents.split(separator: ",").map(String.init))
        let active = store.activeAgents()
        return Agent.allCases.filter {
            store.present.contains($0) && !hidden.contains($0.rawValue) && (showInactive || active.contains($0))
        }
    }

    /// nil = no detail section; agent nil = all agents combined.
    private var detailFilter: (agent: Agent?, title: String)? {
        if detailAgent == "all" { return (nil, "All agents") }
        if let a = Agent(rawValue: detailAgent) { return (a, a.rawValue) }
        return nil
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// The standard About panel (icon, name, version from Info.plist) with a short description.
func showAbout() {
    let text = """
        Token usage, plan limits and alerts for your AI coding agents: \
        Claude Code, Codex, Copilot CLI, Gemini CLI and Grok.

        Reads the agents' own logs on this Mac. Nothing is uploaded.

        Author: Daniel Nguyen
        """
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let credits = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: para,
    ])
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
}

// MARK: - Agent card

private struct AgentCard: View {
    let agent: Agent
    let today: Totals?
    let quota: AgentQuota?
    let includeCacheReads: Bool
    let selected: Bool
    let toggleDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(agent.fill).frame(width: 8, height: 8)
                Text(agent.rawValue).font(.subheadline.weight(.semibold))
                Image(systemName: selected ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let t = today {
                    Text("\(compact(t.total(includeCacheReads: includeCacheReads))) today")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("idle today").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleDetail)
            .help(selected ? "Hide details" : "Show details below")

            if let q = quota {
                ForEach(q.windows) { QuotaLine(window: $0) }
                if let t = q.asOf, Date().timeIntervalSince(t) > 15 * 60 {
                    Text("as of \(t.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let note = q.note {
                    Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                    if note == ClaudeTokenRenewer.signInAgain {
                        Button("Sign in with Terminal…") { ClaudeSignIn.openTerminal() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct QuotaLine: View {
    let window: QuotaWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(window.name).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            if let p = window.percent {
                GradientBar(percent: p)
                Text("\(Int(p.rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text(window.detail ?? "").font(.caption)
                Spacer()
            }
            Text(shortReset(window.resetsAt)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .help(window.percent != nil ? [window.detail, resetText(window.resetsAt)].compactMap { $0 }.joined(separator: " · ") : "")
    }

    private func shortReset(_ d: Date?) -> String {
        guard let s = resetText(d) else { return "" }
        return s.hasPrefix("resets in ") ? String(s.dropFirst("resets in ".count)) : s
    }
}

// MARK: - Detail section

private struct DetailSection: View {
    let agent: Agent?
    let title: String
    let close: () -> Void

    @EnvironmentObject var store: UsageStore
    @AppStorage("period") private var periodRaw = Period.today.rawValue
    @AppStorage("includeCacheReads") private var includeCacheReads = true
    @AppStorage("detailBreakdown") private var showBreakdown = true
    @AppStorage("detailChart") private var showChart = true
    @AppStorage("detailModels") private var showModels = true
    @AppStorage("chartDays") private var chartDays = 14

    var body: some View {
        let period = Period(rawValue: periodRaw) ?? .today
        let events = agent.map { a in store.events.filter { $0.agent == a } } ?? store.events
        let s = Summary(events: events, since: period.start())
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let a = agent { Circle().fill(a.fill).frame(width: 8, height: 8) }
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.borderless).help("Hide details")
            }
            Picker("Period", selection: $periodRaw) {
                ForEach(Period.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(grouped(s.overall.total(includeCacheReads: includeCacheReads)))
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("tokens · \(grouped(s.overall.requests)) requests")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showBreakdown { Breakdown(t: s.overall) }
            if agent == nil && s.byAgent.count > 1 {
                VStack(spacing: 3) {
                    ForEach(Agent.allCases.filter { s.byAgent[$0] != nil }) { a in
                        HStack {
                            Circle().fill(a.fill).frame(width: 6, height: 6)
                            Text(a.rawValue)
                            Spacer()
                            Text(compact(s.byAgent[a]!.total(includeCacheReads: includeCacheReads))).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
            if showChart {
                Text("Last \(chartDays) days").font(.caption).foregroundStyle(.secondary)
                DailyChart(points: dailyPoints(events, days: chartDays, includeCacheReads: includeCacheReads),
                           days: chartDays)
            }
            if showModels && !s.byModel.isEmpty {
                Text("Models").font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 3) {
                    ForEach(s.byModel.prefix(5)) { m in
                        HStack {
                            Circle().fill(m.agent.fill).frame(width: 6, height: 6)
                            Text(m.model).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(compact(m.totals.total(includeCacheReads: includeCacheReads))).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// Green-to-red gradient laid across the whole track and revealed up to `percent`,
/// so the colour at the tip tells how close the limit is.
struct GradientBar: View {
    let percent: Double

    private static let gradient = LinearGradient(
        colors: [Color(red: 0.13, green: 0.88, blue: 0.48), Color(red: 1.00, green: 0.84, blue: 0.04),
                 Color(red: 1.00, green: 0.54, blue: 0.00), Color(red: 1.00, green: 0.18, blue: 0.33)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geo in
            let fill = geo.size.width * min(max(percent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Self.gradient
                    .frame(width: geo.size.width)
                    .mask(alignment: .leading) { Capsule().frame(width: max(fill, fill > 0 ? 6 : 0)) }
            }
        }
        .frame(height: 6)
    }
}

private struct Breakdown: View {
    let t: Totals
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            GridRow { cell("Input", t.input); cell("Output", t.output) }
            GridRow { cell("Cache read", t.cacheRead); cell("Cache write", t.cacheWrite) }
        }
        .font(.caption)
    }

    private func cell(_ name: String, _ n: Int) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(compact(n)).monospacedDigit()
        }
        .frame(width: 148)
    }
}

private struct DailyChart: View {
    let points: [DayPoint]
    let days: Int

    var body: some View {
        Chart(points) { p in
            BarMark(x: .value("Day", p.day, unit: .day), y: .value("Tokens", p.tokens))
                .foregroundStyle(by: .value("Agent", p.agent.rawValue))
        }
        .chartForegroundStyleScale(domain: Agent.allCases.map(\.rawValue),
                                   range: Agent.allCases.map {
                                       LinearGradient(colors: $0.gradientColors.reversed(),
                                                      startPoint: .bottom, endPoint: .top)
                                   })
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let n = v.as(Int.self) { Text(compact(n)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, days / 5))) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 100)
    }
}
