import SwiftUI

struct PreferencesView: View {
    // Not @State: in this SDK @State is a macro whose plugin only ships with Xcode.
    @AppStorage("prefsTab") private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            DisplayPane().tabItem { Label("Display", systemImage: "rectangle.3.group") }.tag(1)
            AgentsPane().tabItem { Label("Agents", systemImage: "person.2") }.tag(2)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralPane: View {
    @EnvironmentObject var store: UsageStore
    @AppStorage("menuBarShows") private var menuBarShows = "tokens"
    @AppStorage("refreshMinutes") private var refreshMinutes = 1
    @AppStorage("includeCacheReads") private var includeCacheReads = true
    @AppStorage("quotaAlerts") private var quotaAlerts = true
    @AppStorage("resetAlerts") private var resetAlerts = ResetAlerts.afterWarning.rawValue

    /// Agents that report quota, plus whatever is currently selected.
    private var quotaAgents: [Agent] {
        Agent.allCases.filter { a in
            store.quotas[a]?.windows.isEmpty == false || menuBarShows == "quota:" + a.rawValue
                || (a == .claude && menuBarShows == "claudeQuota")
        }
    }

    var body: some View {
        Form {
            Section {
            Picker("Menu bar shows", selection: Binding(
                get: { menuBarShows == "claudeQuota" ? "quota:" + Agent.claude.rawValue : menuBarShows },
                set: { menuBarShows = $0 })) {
                Text("Today's tokens").tag("tokens")
                Text("Highest quota, any agent").tag("peakQuota")
                ForEach(quotaAgents) { a in Text("\(a.rawValue) quota").tag("quota:" + a.rawValue) }
                Text("Icon only").tag("icon")
            }
            Picker("Refresh every", selection: $refreshMinutes) {
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
            }
            Toggle("Count cache reads in token totals", isOn: $includeCacheReads)
            Toggle("Open at login", isOn: Binding(get: { store.opensAtLogin },
                                                   set: { store.setOpensAtLogin($0) }))
            if let err = store.loginError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            }

            Section {
                Toggle("Notify when a quota reaches 80% and 95%", isOn: $quotaAlerts)
                Picker("Notify when a limit resets", selection: $resetAlerts) {
                    Text("After a warning").tag(ResetAlerts.afterWarning.rawValue)
                    Text("Always").tag(ResetAlerts.always.rawValue)
                    Text("Never").tag(ResetAlerts.never.rawValue)
                }
                .disabled(!quotaAlerts)
                Button("Send a test notification") { Notifier.shared.sendTest() }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Each threshold notifies once per quota window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplayPane: View {
    @EnvironmentObject var store: UsageStore
    @AppStorage("showInactive") private var showInactive = false
    @AppStorage("hiddenAgents") private var hiddenAgents = ""
    @AppStorage("detailAgent") private var detailAgent = ""
    @AppStorage("detailBreakdown") private var showBreakdown = true
    @AppStorage("detailChart") private var showChart = true
    @AppStorage("detailModels") private var showModels = true
    @AppStorage("chartDays") private var chartDays = 14

    var body: some View {
        Form {
            Section {
                Toggle("Include agents with no use in 30 days", isOn: $showInactive)
                ForEach(Agent.allCases) { a in
                    Toggle(isOn: visible(a)) {
                        HStack {
                            Circle().fill(a.fill).frame(width: 8, height: 8)
                            Text(a.rawValue)
                            if !store.present.contains(a) {
                                Text("not installed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!store.present.contains(a))
                }
            } header: {
                Text("Agents in the menu")
            }

            Section {
                Picker("Show details for", selection: $detailAgent) {
                    Text("Nothing").tag("")
                    Text("All agents combined").tag("all")
                    Divider()
                    ForEach(Agent.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("Token breakdown", isOn: $showBreakdown)
                Toggle("Daily chart", isOn: $showChart)
                Picker("Chart covers", selection: $chartDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .disabled(!showChart)
                Toggle("Top models", isOn: $showModels)
            } header: {
                Text("Detail section")
            } footer: {
                Text("Clicking an agent's name in the menu also shows or hides its details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func visible(_ a: Agent) -> Binding<Bool> {
        Binding(
            get: { !hiddenAgents.split(separator: ",").contains(Substring(a.rawValue)) },
            set: { on in
                var set = Set(hiddenAgents.split(separator: ",").map(String.init))
                if on { set.remove(a.rawValue) } else { set.insert(a.rawValue) }
                hiddenAgents = set.sorted().joined(separator: ",")
            })
    }
}

struct AgentsPane: View {
    @EnvironmentObject var store: UsageStore
    @AppStorage("claudeLiveQuota") private var liveQuota = false
    @AppStorage("claudeAutoRenew") private var autoRenew = true
    @AppStorage("copilotAllowance") private var copilotAllowance = 0

    var body: some View {
        Form {
            Section {
                Picker("Limits", selection: $liveQuota) {
                    Text("From this Mac").tag(false)
                    Text("Live, with Terminal sign-in").tag(true)
                }
                if liveQuota {
                    LabeledContent("Sign-in", value: store.claudeSignIn.isEmpty ? "Checking…" : store.claudeSignIn)
                    Button("Sign in with Terminal…") { ClaudeSignIn.openTerminal() }
                    Toggle("Renew the sign-in when it expires", isOn: $autoRenew)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text(liveQuota
                     ? "Asks Anthropic every 5 minutes, using the sign-in of the claude command-line tool. "
                       + "That sign-in lasts a limited time; when it ends, sign in again with Terminal. "
                       + "The newest numbers from this Mac are still used when they are fresher."
                     : "Reads the percentages the Claude desktop app saves on this Mac, about every 15 minutes "
                       + "while it is in use. No sign-in, nothing is sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Monthly premium requests", value: $copilotAllowance, format: .number)
            } header: {
                Text("Copilot CLI")
            } footer: {
                Text("Your plan's allowance (e.g. 300 for Pro, 1500 for Pro+). 0 shows only the count.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Codex", value: "From its session logs")
                LabeledContent("Gemini CLI", value: "Not kept on this Mac")
                LabeledContent("Grok", value: "Not kept on this Mac")
                LabeledContent("Antigravity", value: "Not kept on this Mac")
            } header: {
                Text("Other agents' limits")
            } footer: {
                Text("These need no sign-in here. Gemini CLI, Grok and Antigravity show their limits only in their own apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.checkClaudeSignIn() }
        .onChange(of: liveQuota) { store.refresh(forceQuota: true); store.checkClaudeSignIn() }
        .onChange(of: copilotAllowance) { store.refresh() }
    }
}
