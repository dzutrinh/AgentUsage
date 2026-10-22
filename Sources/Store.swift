import Foundation
import ServiceManagement

/// Runs the readers. Only one scan runs at a time (guarded by UsageStore.isLoading).
final class Scanner: @unchecked Sendable {
    private let codex = CodexSource()
    private let copilot = CopilotSource()
    private let claudeQuota = ClaudeQuotaSource()
    private lazy var sources: [UsageSource] = [ClaudeSource(), codex, GeminiSource(), copilot, GrokSource()]

    struct Result {
        var events: [UsageEvent]
        var present: Set<Agent>
        var quotas: [Agent: AgentQuota]
    }

    /// `forceQuota` asks Anthropic again even if the last check was under 5 minutes ago.
    func scan(forceQuota: Bool = false) -> Result {
        var all: [UsageEvent] = []
        var present = Set<Agent>()
        for s in sources {
            if s.isPresent { present.insert(s.agent) }
            all += s.collect()
        }
        var quotas: [Agent: AgentQuota] = [:]
        let d = UserDefaults.standard
        if present.contains(.claude) {
            quotas[.claude] = claudeQuota.quota(force: forceQuota,
                                                live: d.object(forKey: "claudeLiveQuota") as? Bool ?? true,
                                                autoRenew: d.object(forKey: "claudeAutoRenew") as? Bool ?? true)
        }
        quotas[.codex] = codex.quota
        quotas[.copilot] = copilot.quota(allowance: UserDefaults.standard.integer(forKey: "copilotAllowance"))
        return Result(events: dedupe(all), present: present, quotas: quotas)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var events: [UsageEvent] = []
    @Published private(set) var present: Set<Agent> = []
    @Published private(set) var quotas: [Agent: AgentQuota] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published var loginError: String?

    private let scanner = Scanner()
    private var timer: Timer?

    /// True for fixed demo data: refresh() never replaces it with real logs.
    private var frozen = false

    /// Fixed data and no scanning, for screenshots.
    init(snapshot: Scanner.Result) {
        frozen = true
        events = snapshot.events
        present = snapshot.present
        quotas = snapshot.quotas
        lastUpdated = Date()
    }

    init() {
        Notifier.shared.setUp()
        if CommandLine.arguments.contains("--test-notification") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Notifier.shared.sendTest() }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfDue() }
        }
    }

    /// Honors the "Refresh every" preference (minutes, default 1).
    private func refreshIfDue() {
        let minutes = max(1, UserDefaults.standard.integer(forKey: "refreshMinutes"))
        if Date().timeIntervalSince(lastUpdated ?? .distantPast) >= Double(minutes) * 60 - 5 { refresh() }
    }

    func refresh(forceQuota: Bool = false) {
        guard !isLoading, !frozen else { return }
        isLoading = true
        let scanner = self.scanner
        Task.detached(priority: .utility) {
            let result = scanner.scan(forceQuota: forceQuota)
            await MainActor.run {
                self.events = result.events
                self.present = result.present
                self.quotas = result.quotas
                self.checkAlerts()
                self.lastUpdated = Date()
                self.isLoading = false
            }
        }
    }

    func todayTotal(includeCacheReads: Bool) -> Int {
        Summary(events: events, since: Period.today.start()).overall.total(includeCacheReads: includeCacheReads)
    }

    private func checkAlerts() {
        let d = UserDefaults.standard
        guard d.object(forKey: "quotaAlerts") as? Bool ?? true else { return }
        let resets = ResetAlerts(rawValue: d.string(forKey: "resetAlerts") ?? "") ?? .afterWarning
        var state = (d.data(forKey: "alertState"))
            .flatMap { try? JSONDecoder().decode([String: AlertState].self, from: $0) } ?? [:]
        for (agent, q) in quotas {
            let r = AlertRules.evaluate(agent: agent, quota: q, state: state, resets: resets)
            state = r.state
            r.alerts.forEach(Notifier.shared.send)
        }
        if let data = try? JSONEncoder().encode(state) { d.set(data, forKey: "alertState") }
    }

    /// Highest window in use for one agent, for the menu bar.
    func peakPercent(_ agent: Agent) -> Double? {
        quotas[agent]?.windows.compactMap(\.percent).max()
    }

    /// Highest window across all agents, for the menu bar.
    var peakPercent: Double? {
        quotas.values.flatMap(\.windows).compactMap(\.percent).max()
    }

    /// Installed agents used in the last 30 days or with quota in use.
    func activeAgents() -> Set<Agent> {
        let recent = Summary(events: events, since: Period.month.start())
        return Set(Agent.allCases.filter { a in
            present.contains(a) && (recent.byAgent[a] != nil
                || quotas[a]?.windows.contains { ($0.percent ?? 0) > 0 } == true)
        })
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        objectWillChange.send()
    }
}
