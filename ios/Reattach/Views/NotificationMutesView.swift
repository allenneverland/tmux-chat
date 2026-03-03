//
//  NotificationMutesView.swift
//  Reattach
//

import SwiftUI

private enum MuteDurationOption: String, CaseIterable, Identifiable {
    case oneHour
    case eightHours
    case oneDay
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour:
            return "1 hour"
        case .eightHours:
            return "8 hours"
        case .oneDay:
            return "24 hours"
        case .forever:
            return "Forever"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .oneHour:
            return 60 * 60
        case .eightHours:
            return 8 * 60 * 60
        case .oneDay:
            return 24 * 60 * 60
        case .forever:
            return nil
        }
    }
}

private struct PaneMuteCandidate: Identifiable, Hashable {
    let target: String
    let label: String

    var id: String { target }
}

struct NotificationMutesView: View {
    let server: ServerConfig

    private let api = ReattachAPI.shared
    @State private var rules: [MuteRule] = []
    @State private var sessions: [Session] = []
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var showError = false
    @State private var errorMessage = ""

    @State private var selectedScope: MuteScope = .host
    @State private var selectedSource: MuteSource = .all
    @State private var selectedDuration: MuteDurationOption = .oneHour
    @State private var selectedSessionName = ""
    @State private var selectedPaneTarget = ""

    private var deviceApiToken: String? {
        let token = server.deviceApiToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }

    private var sessionNames: [String] {
        sessions.map(\.name).sorted()
    }

    private var paneCandidates: [PaneMuteCandidate] {
        sessions.flatMap { session in
            session.windows.flatMap { window in
                window.panes.map { pane in
                    PaneMuteCandidate(
                        target: pane.target,
                        label: "\(session.name) · \(window.name) · Pane \(pane.index)"
                    )
                }
            }
        }
    }

    private var canCreateMute: Bool {
        guard deviceApiToken != nil else { return false }
        guard !isSubmitting else { return false }

        switch selectedScope {
        case .host:
            return true
        case .session:
            return !selectedSessionName.isEmpty
        case .pane:
            return !selectedPaneTarget.isEmpty
        }
    }

    var body: some View {
        Form {
            if deviceApiToken == nil {
                Section {
                    Text("This server is missing a push device token. Re-run SSH onboarding to manage notification mutes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                createMuteSection
                activeMutesSection
            }
        }
        .navigationTitle("Notification Mutes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await loadData()
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(deviceApiToken == nil || isLoading || isSubmitting)
            }
        }
        .task {
            await loadData()
        }
        .onChange(of: selectedScope) { _, _ in
            syncSelectionsWithAvailableTargets()
        }
        .alert("Mute Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private var createMuteSection: some View {
        Section("Add Mute") {
            Picker("Scope", selection: $selectedScope) {
                ForEach(MuteScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }

            if selectedScope == .session {
                if sessionNames.isEmpty {
                    Text("No sessions found on this server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Session", selection: $selectedSessionName) {
                        ForEach(sessionNames, id: \.self) { sessionName in
                            Text(sessionName).tag(sessionName)
                        }
                    }
                }
            }

            if selectedScope == .pane {
                if paneCandidates.isEmpty {
                    Text("No panes found on this server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Pane", selection: $selectedPaneTarget) {
                        ForEach(paneCandidates) { pane in
                            Text(pane.label).tag(pane.target)
                        }
                    }
                }
            }

            Picker("Source", selection: $selectedSource) {
                ForEach(MuteSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }

            Picker("Duration", selection: $selectedDuration) {
                ForEach(MuteDurationOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Button {
                Task {
                    await createMute()
                }
            } label: {
                HStack {
                    if isSubmitting {
                        ProgressView()
                    }
                    Text("Add Mute")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!canCreateMute)
        }
    }

    @ViewBuilder
    private var activeMutesSection: some View {
        Section("Active Mutes") {
            if isLoading && rules.isEmpty {
                ProgressView("Loading mutes...")
            } else if rules.isEmpty {
                Text("No active mute rules")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rulePrimaryText(rule))
                            .font(.body)
                        Text(ruleSecondaryText(rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task {
                                await deleteMute(rule)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func loadData() async {
        guard deviceApiToken != nil else { return }

        isLoading = true
        defer { isLoading = false }

        var loadedRules: [MuteRule] = []
        var loadedSessions: [Session] = []
        var firstError: Error?

        do {
            loadedRules = try await api.listMutes(deviceApiToken: deviceApiToken)
        } catch {
            firstError = error
        }

        do {
            loadedSessions = try await api.listSessions(for: server)
        } catch {
            firstError = firstError ?? error
        }

        rules = loadedRules
        sessions = loadedSessions
        syncSelectionsWithAvailableTargets()

        if let firstError {
            present(error: firstError)
        }
    }

    private func syncSelectionsWithAvailableTargets() {
        let names = sessionNames
        if !names.contains(selectedSessionName) {
            selectedSessionName = names.first ?? ""
        }

        let paneTargets = Set(paneCandidates.map(\.target))
        if !paneTargets.contains(selectedPaneTarget) {
            selectedPaneTarget = paneCandidates.first?.target ?? ""
        }
    }

    private func createMute() async {
        guard let deviceApiToken else {
            present(message: "This server is missing a push device token.")
            return
        }

        var requestBody = CreateMuteRequestBody(
            scope: selectedScope,
            sessionName: nil,
            paneTarget: nil,
            source: selectedSource,
            until: makeUntilTimestamp(option: selectedDuration)
        )

        switch selectedScope {
        case .host:
            break
        case .session:
            requestBody = CreateMuteRequestBody(
                scope: .session,
                sessionName: selectedSessionName,
                paneTarget: nil,
                source: selectedSource,
                until: makeUntilTimestamp(option: selectedDuration)
            )
        case .pane:
            requestBody = CreateMuteRequestBody(
                scope: .pane,
                sessionName: nil,
                paneTarget: selectedPaneTarget,
                source: selectedSource,
                until: makeUntilTimestamp(option: selectedDuration)
            )
        }

        isSubmitting = true
        defer { isSubmitting = false }

        if let existing = rules.first(where: { $0.scope == requestBody.scope && $0.sessionName == requestBody.sessionName && $0.paneTarget == requestBody.paneTarget && $0.source == requestBody.source }) {
            _ = try? await api.deleteMute(id: existing.id, deviceApiToken: deviceApiToken)
        }

        do {
            _ = try await api.createMute(requestBody, deviceApiToken: deviceApiToken)
            rules = try await api.listMutes(deviceApiToken: deviceApiToken)
        } catch {
            present(error: error)
        }
    }

    private func deleteMute(_ rule: MuteRule) async {
        guard let deviceApiToken else {
            present(message: "This server is missing a push device token.")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await api.deleteMute(id: rule.id, deviceApiToken: deviceApiToken)
            rules.removeAll { $0.id == rule.id }
        } catch {
            present(error: error)
        }
    }

    private func rulePrimaryText(_ rule: MuteRule) -> String {
        switch rule.scope {
        case .host:
            return "Host"
        case .session:
            return "Session · \(rule.sessionName ?? "-")"
        case .pane:
            return "Pane · \(rule.paneTarget ?? "-")"
        }
    }

    private func ruleSecondaryText(_ rule: MuteRule) -> String {
        let source = "Source: \(rule.source.title)"
        let until = "Until: \(formatTimestamp(rule.until))"
        return "\(source) · \(until)"
    }

    private func formatTimestamp(_ raw: String?) -> String {
        guard let raw else { return "Forever" }
        guard let date = parseTimestamp(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func makeUntilTimestamp(option: MuteDurationOption) -> String? {
        guard let interval = option.timeInterval else { return nil }
        let until = Date().addingTimeInterval(interval)
        return Self.timestampFormatter.string(from: until)
    }

    private func parseTimestamp(_ raw: String) -> Date? {
        if let parsed = Self.timestampFormatter.date(from: raw) {
            return parsed
        }
        return Self.timestampFormatterWithoutFractional.date(from: raw)
    }

    private func present(error: Error) {
        if let error = error as? APIError {
            present(message: error.localizedDescription)
        } else {
            present(message: error.localizedDescription)
        }
    }

    private func present(message: String) {
        errorMessage = message
        showError = true
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampFormatterWithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

#Preview {
    NavigationStack {
        NotificationMutesView(server: ServerConfig(
            serverURL: "https://example.com",
            controlToken: "control-token",
            deviceId: "device-id",
            deviceName: "iPhone",
            serverName: "Home",
            deviceApiToken: "device-api-token",
            registeredAt: Date()
        ))
    }
}
