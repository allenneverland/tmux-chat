//
//  SessionListView.swift
//  TmuxChat
//

import SwiftUI
import Observation

// MARK: - PaneIcon

enum PaneIcon {
    static func iconName(for windowName: String, path: String = "") -> String {
        let name = windowName.lowercased()
        let pathLower = path.lowercased()

        if name.contains("docker") || name.contains("container") {
            return "shippingbox.fill"
        }
        if name.contains("claude") || pathLower.contains("claude") {
            return "sparkles"
        }
        if name.contains("vim") || name.contains("nvim") || name.contains("neovim") {
            return "doc.text.fill"
        }
        if name.contains("git") {
            return "arrow.triangle.branch"
        }
        if name.contains("node") || name.contains("npm") || name.contains("yarn") || name.contains("pnpm") {
            return "cube.fill"
        }
        if name.contains("python") || name.contains("pip") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("cargo") || name.contains("rust") {
            return "gearshape.fill"
        }
        if name.contains("ssh") {
            return "network"
        }
        if name.contains("htop") || name.contains("top") || name.contains("btop") {
            return "chart.bar.fill"
        }
        if name.contains("man") {
            return "book.fill"
        }
        if name.contains("make") || name.contains("build") {
            return "hammer.fill"
        }
        if name.contains("test") {
            return "checkmark.circle.fill"
        }

        return "terminal"
    }

    static func iconColor(for windowName: String, isActive: Bool) -> Color {
        let name = windowName.lowercased()

        if !isActive {
            return .secondary
        }

        if name.contains("docker") {
            return .blue
        }
        if name.contains("claude") {
            return .orange
        }
        if name.contains("vim") || name.contains("nvim") {
            return .green
        }
        if name.contains("git") {
            return .orange
        }
        if name.contains("node") || name.contains("npm") {
            return .green
        }
        if name.contains("python") {
            return .yellow
        }
        if name.contains("cargo") || name.contains("rust") {
            return .orange
        }
        if name.contains("ssh") {
            return .purple
        }

        return .blue
    }
}

// MARK: - SessionListView

struct SessionListView: View {
    @State private var viewModel = SessionListViewModel()
    @State private var showingCreateSheet = false
    @State private var showRepairOnboarding = false
    @State private var selectedPane: PaneNavigationItem?
    @State private var navigationPath = NavigationPath()
    @State private var unreadPaneKeys: Set<String> = []

    private var unreadPanes: Set<String> {
        guard let deviceId = ServerConfigManager.shared.activeServer?.deviceId else {
            return []
        }
        let prefix = "\(deviceId):"
        return Set(unreadPaneKeys.compactMap { key in
            key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        })
    }
    @State private var showServerList = false
    @State private var showServerSettings = false
    @State private var configManager = ServerConfigManager.shared
    @State private var paneToDelete: Pane?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateSessionView { name, cwd in
                await viewModel.createSession(name: name, cwd: cwd)
            }
        }
        .sheet(isPresented: $showRepairOnboarding) {
            SSHOnboardingView(serverToRepair: configManager.activeServer) {
                Task {
                    await viewModel.loadSessions()
                }
            }
        }
        .sheet(isPresented: $showServerList) {
            ServerListView()
        }
        .sheet(isPresented: $showServerSettings) {
            if let server = configManager.activeServer {
                NavigationStack {
                    ServerDetailView(server: server)
                }
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .task {
            await viewModel.loadSessions()
            unreadPaneKeys = AppDelegate.shared?.unreadPanes ?? []
            handlePendingNavigation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPane)) { notification in
            guard let deviceId = notification.userInfo?["deviceId"] as? String,
                  let paneTarget = notification.userInfo?["paneTarget"] as? String else { return }
            Task {
                await routeToPane(deviceId: deviceId, paneTarget: paneTarget)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .unreadPanesChanged)) { _ in
            unreadPaneKeys = AppDelegate.shared?.unreadPanes ?? []
        }
        .onReceive(NotificationCenter.default.publisher(for: .authenticationRestored)) { _ in
            Task {
                await viewModel.loadSessions()
                handlePendingNavigation()
            }
        }
        .onChange(of: configManager.activeServerId) { _, _ in
            Task {
                await viewModel.loadSessions()
            }
        }
    }

    // MARK: - iPhone Layout (NavigationStack)
    private var compactLayout: some View {
        NavigationStack(path: $navigationPath) {
            listContent
                .navigationTitle(currentServerName)
                .navigationDestination(for: PaneNavigationItem.self) { item in
                    PaneDetailView(pane: item.pane, windowName: item.windowName)
                        .onAppear {
                            if let deviceId = ServerConfigManager.shared.activeServer?.deviceId {
                                AppDelegate.shared?.markPaneAsRead(deviceId: deviceId, paneTarget: item.pane.target)
                            }
                        }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        serverListButton
                    }
                    ToolbarItem(placement: .primaryAction) {
                        settingsButton
                    }
                }
        }
    }

    // MARK: - iPad Layout (NavigationSplitView)
    private var regularLayout: some View {
        NavigationSplitView {
            listContent
                .navigationTitle(currentServerName)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        serverListButton
                    }
                    ToolbarItem(placement: .primaryAction) {
                        settingsButton
                    }
                }
        } detail: {
            if let selected = selectedPane {
                PaneDetailView(pane: selected.pane, windowName: selected.windowName)
                    .id(selected.pane.target)
                    .onAppear {
                        if let deviceId = ServerConfigManager.shared.activeServer?.deviceId {
                            AppDelegate.shared?.markPaneAsRead(deviceId: deviceId, paneTarget: selected.pane.target)
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Select a Pane",
                    systemImage: "terminal",
                    description: Text("Choose a pane from the sidebar")
                )
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.connectionState {
        case .checking where viewModel.sessions.isEmpty:
            ProgressView("Loading sessions...")
        case .unauthorized:
            blockingRecoveryView(
                title: "Server Authentication Expired",
                description: "The server rejected this device token. Reconnect and re-pair this server to restore control."
            )
        case .unsupportedServer(let message):
            blockingRecoveryView(
                title: "Server Upgrade Required",
                description: message
            )
        case .contextMismatch(let message):
            blockingRecoveryView(
                title: "tmux User Context Mismatch",
                description: message
            )
        case .unreachable(let message):
            blockingRecoveryView(
                title: "Server Unreachable",
                description: message
            )
        case .serverError(let message):
            blockingRecoveryView(
                title: "Server Error",
                description: message
            )
        default:
            List {
                if viewModel.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Connected successfully. Create a new session to get started.")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if !viewModel.sessions.isEmpty && TmuxChatAPI.shared.isDemoMode {
                    Section {
                        HStack {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Demo Mode")
                                    .font(.headline)
                                Text("Showing sample data. Set up a server to connect.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let diagnostics = viewModel.diagnostics {
                    Section("Host Context") {
                        HStack {
                            Text("Daemon user")
                            Spacer()
                            Text(diagnostics.daemonUser)
                                .foregroundStyle(.secondary)
                        }
                        if let socket = diagnostics.tmuxSocket, !socket.isEmpty {
                            HStack {
                                Text("tmux socket")
                                Spacer()
                                Text(socket)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                ForEach(viewModel.sessions) { session in
                    SessionSection(
                        session: session,
                        unreadPanes: unreadPanes,
                        isCompact: horizontalSizeClass == .compact,
                        selectedPane: $selectedPane,
                        navigationPath: $navigationPath,
                        onRequestDelete: { pane in
                            paneToDelete = pane
                        },
                        onDeletePane: { target in
                            await viewModel.deletePane(target: target)
                        }
                    )
                }
                Section {
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Label("New Session", systemImage: "plus.circle")
                    }
                    .disabled(!viewModel.canCreateSession)
                }
            }
            .listStyle(.sidebar)
            .refreshable {
                await viewModel.loadSessions()
            }
            .confirmationDialog(
                "Delete Pane",
                isPresented: Binding(
                    get: { paneToDelete != nil },
                    set: { if !$0 { paneToDelete = nil } }
                ),
                presenting: paneToDelete
            ) { pane in
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deletePane(target: pane.target)
                        paneToDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    paneToDelete = nil
                }
            } message: { pane in
                Text("Are you sure you want to delete this pane?\n\(pane.shortPath)")
            }
        }
    }

    private func handlePendingNavigation() {
        guard let key = AppDelegate.shared?.pendingNavigationTarget else { return }
        AppDelegate.shared?.pendingNavigationTarget = nil
        navigateToPaneWithKey(key)
    }

    private func navigateToPaneWithKey(_ key: String) {
        let components = key.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else {
            viewModel.errorMessage = "Notification payload is invalid."
            viewModel.showError = true
            return
        }
        let deviceId = String(components[0])
        let paneTarget = String(components[1])

        Task {
            await routeToPane(deviceId: deviceId, paneTarget: paneTarget)
        }
    }

    private func routeToPane(deviceId: String, paneTarget: String) async {
        let targetServerExists = ServerConfigManager.shared.servers.contains { $0.deviceId == deviceId }
        guard targetServerExists else {
            await NotificationMetricsReporter.shared.recordRouteFallback(deviceId: deviceId)
            showNavigationFallback(message: "The server for this notification is no longer configured.")
            return
        }

        ServerConfigManager.shared.setActiveServer(deviceId)
        await viewModel.loadSessions()

        let routed = navigateToPaneWithTarget(paneTarget)
        if !routed {
            await NotificationMetricsReporter.shared.recordRouteFallback(deviceId: deviceId)
            showNavigationFallback(message: "Pane \(paneTarget) no longer exists. Showing session list instead.")
            return
        }

        await NotificationMetricsReporter.shared.recordRouteSuccess(deviceId: deviceId)
    }

    private func navigateToPaneWithTarget(_ paneTarget: String) -> Bool {
        for session in viewModel.sessions {
            for window in session.windows {
                for pane in window.panes {
                    if pane.target == paneTarget {
                        let item = PaneNavigationItem(pane: pane, windowName: window.name)
                        if horizontalSizeClass == .compact {
                            navigationPath = NavigationPath()
                            navigationPath.append(item)
                        } else {
                            selectedPane = item
                        }
                        return true
                    }
                }
            }
        }

        return false
    }

    private func showNavigationFallback(message: String) {
        if horizontalSizeClass == .compact {
            navigationPath = NavigationPath()
        } else {
            selectedPane = nil
        }
        viewModel.errorMessage = message
        viewModel.showError = true
    }

    private func blockingRecoveryView(title: String, description: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let diagnostics = viewModel.diagnostics {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Daemon user: \(diagnostics.daemonUser)")
                        .font(.caption)
                    if let socket = diagnostics.tmuxSocket, !socket.isEmpty {
                        Text("tmux socket: \(socket)")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
            }

            Button {
                showRepairOnboarding = true
            } label: {
                Text("Reconnect & Re-pair")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)

            Button {
                showServerList = true
            } label: {
                Text("Manage Servers")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)

            Button {
                Task {
                    await viewModel.loadSessions()
                }
            } label: {
                Text("Retry")
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var serverListButton: some View {
        Button {
            showServerList = true
        } label: {
            Image(systemName: "list.bullet")
        }
    }

    private var currentServerName: String {
        if configManager.isDemoMode {
            return "Demo"
        } else if let server = configManager.activeServer {
            return server.serverName
        }
        return ""
    }

    @ViewBuilder
    private var settingsButton: some View {
        if !configManager.isDemoMode && configManager.activeServer != nil {
            Button {
                showServerSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }
}

// MARK: - PaneNavigationItem

struct PaneNavigationItem: Hashable {
    let pane: Pane
    let windowName: String
}

// MARK: - SessionSection

struct SessionSection: View {
    let session: Session
    let unreadPanes: Set<String>
    let isCompact: Bool
    @Binding var selectedPane: PaneNavigationItem?
    @Binding var navigationPath: NavigationPath
    var onRequestDelete: (Pane) -> Void
    var onDeletePane: (String) async -> Void

    var body: some View {
        Section {
            ForEach(session.windows) { window in
                WindowRow(
                    window: window,
                    sessionName: session.name,
                    unreadPanes: unreadPanes,
                    isCompact: isCompact,
                    selectedPane: $selectedPane,
                    navigationPath: $navigationPath,
                    onRequestDelete: onRequestDelete
                )
                .listRowSeparator(.visible)
            }
        } header: {
            HStack {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(session.attached ? .green : .secondary)
                Text(session.name)
                    .font(.headline)
                Spacer()
                if session.attached {
                    Text("attached")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
    }
}

// MARK: - WindowRow

struct WindowRow: View {
    let window: Window
    let sessionName: String
    let unreadPanes: Set<String>
    let isCompact: Bool
    @Binding var selectedPane: PaneNavigationItem?
    @Binding var navigationPath: NavigationPath
    var onRequestDelete: (Pane) -> Void

    private var hasUnreadPane: Bool {
        window.panes.contains { unreadPanes.contains($0.target) }
    }

    private func isSelected(_ pane: Pane) -> Bool {
        selectedPane?.pane.target == pane.target
    }

    private func selectPane(_ pane: Pane) {
        let item = PaneNavigationItem(pane: pane, windowName: window.name)
        if isCompact {
            navigationPath.append(item)
        } else {
            selectedPane = item
        }
    }

    var body: some View {
        Group {
            if window.panes.count == 1, let pane = window.panes.first {
                if isCompact {
                    NavigationLink(value: PaneNavigationItem(pane: pane, windowName: window.name)) {
                        WindowLabel(window: window, isUnread: unreadPanes.contains(pane.target))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            onRequestDelete(pane)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } else {
                    Button {
                        selectPane(pane)
                    } label: {
                        WindowLabel(window: window, isUnread: unreadPanes.contains(pane.target))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isSelected(pane) ? Color.accentColor.opacity(0.2) : nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            onRequestDelete(pane)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } else {
                DisclosureGroup {
                    ForEach(window.panes) { pane in
                        if isCompact {
                            NavigationLink(value: PaneNavigationItem(pane: pane, windowName: window.name)) {
                                PaneRow(pane: pane, windowName: window.name, isUnread: unreadPanes.contains(pane.target))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    onRequestDelete(pane)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowSeparator(.visible)
                        } else {
                            Button {
                                selectPane(pane)
                            } label: {
                                PaneRow(pane: pane, windowName: window.name, isUnread: unreadPanes.contains(pane.target))
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(isSelected(pane) ? Color.accentColor.opacity(0.2) : nil)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    onRequestDelete(pane)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowSeparator(.visible)
                        }
                    }
                } label: {
                    WindowLabel(window: window, isUnread: hasUnreadPane)
                }
            }
        }
    }
}

// MARK: - WindowLabel

struct WindowLabel: View {
    let window: Window
    var isUnread: Bool = false

    var body: some View {
        HStack {
            Image(systemName: PaneIcon.iconName(for: window.name, path: window.panes.first?.currentPath ?? ""))
                .foregroundStyle(PaneIcon.iconColor(for: window.name, isActive: window.active))
            VStack(alignment: .leading) {
                Text(window.name)
                    .font(.body)
                HStack(spacing: 4) {
                    Text("Window \(window.index)")
                    if let firstPane = window.panes.first {
                        Text("·")
                        Text(firstPane.shortPath)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if isUnread {
                Spacer()
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - PaneRow

struct PaneRow: View {
    let pane: Pane
    var windowName: String = ""
    var isUnread: Bool = false

    var body: some View {
        HStack {
            Image(systemName: PaneIcon.iconName(for: windowName, path: pane.currentPath))
                .foregroundStyle(PaneIcon.iconColor(for: windowName, isActive: pane.active))
            VStack(alignment: .leading) {
                Text("Pane \(pane.index)")
                    .font(.body)
                Text(pane.shortPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isUnread {
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
            }
            if pane.active {
                Text("active")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - SessionListViewModel

@MainActor
@Observable
class SessionListViewModel {
    enum ServerConnectionState: Equatable {
        case checking
        case ready(sessionCount: Int)
        case readyNoSessions
        case unauthorized
        case contextMismatch(String)
        case unsupportedServer(String)
        case unreachable(String)
        case serverError(String)
    }

    var sessions: [Session] = []
    var isLoading = false
    var showError = false
    var errorMessage = ""
    var connectionState: ServerConnectionState = .checking
    var diagnostics: DaemonDiagnosticsResponse?
    var validatedCapabilitiesServerID: String?

    private let api = TmuxChatAPI.shared

    func loadSessions() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let activeServerID = ServerConfigManager.shared.activeServer?.deviceId
            if validatedCapabilitiesServerID != activeServerID {
                let caps = try await api.getCapabilities(forceRefresh: true)
                guard caps.supportsRequiredShortcutContract else {
                    connectionState = .unsupportedServer(
                        "Current host tmux-chatd does not satisfy required control-plane contract (schema v3 + pane_key_probe). Upgrade host tmux-chatd and reconnect."
                    )
                    updateActiveServerConnectionState("unsupported_server")
                    sessions = []
                    return
                }
                guard caps.endpoints.diagnostics else {
                    connectionState = .unsupportedServer(
                        "tmux-chatd \(caps.version) does not expose diagnostics. Upgrade host tmux-chatd to continue."
                    )
                    updateActiveServerConnectionState("unsupported_server")
                    sessions = []
                    return
                }
                validatedCapabilitiesServerID = activeServerID
            }

            sessions = try await api.listSessions()

            diagnostics = try await api.getDiagnostics()
            if var active = ServerConfigManager.shared.activeServer, let diagnostics {
                active.lastVerifiedDaemonUser = diagnostics.daemonUser
                active.lastConnectionState = sessions.isEmpty ? "ready_no_sessions" : "ready"
                active.lastVerifiedAt = Date()
                ServerConfigManager.shared.updateServer(active)
            }
            if let diagnostics,
               let expectedUser = ServerConfigManager.shared.activeServer?.sshUsername?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expectedUser.isEmpty,
               diagnostics.daemonUser != expectedUser {
                connectionState = .contextMismatch(
                    "tmux-chatd is running as \(diagnostics.daemonUser), but this server was onboarded with SSH user \(expectedUser). Re-pair using the tmux owner account."
                )
                updateActiveServerConnectionState("context_mismatch")
                return
            }

            if sessions.isEmpty {
                connectionState = .readyNoSessions
                updateActiveServerConnectionState("ready_no_sessions")
            } else {
                connectionState = .ready(sessionCount: sessions.count)
                updateActiveServerConnectionState("ready")
            }
        } catch let error as APIError {
            if case .unauthorized = error {
                connectionState = .unauthorized
                updateActiveServerConnectionState("unauthorized")
                sessions = []
                diagnostics = nil
                return
            }
            if case .networkError(let underlying) = error {
                connectionState = .unreachable(underlying.localizedDescription)
                updateActiveServerConnectionState("unreachable")
                sessions = []
                diagnostics = nil
                return
            }
            if case .httpError(let statusCode, let path, _, _) = error,
               statusCode == 404,
               path == "/capabilities" || path == "/diagnostics" || path == "/sessions" {
                connectionState = .unsupportedServer(
                    "Current host tmux-chatd is missing required endpoints (/capabilities or /diagnostics). Upgrade host tmux-chatd, then retry."
                )
                updateActiveServerConnectionState("unsupported_server")
                sessions = []
                diagnostics = nil
                return
            }
            connectionState = .serverError(error.localizedDescription)
            updateActiveServerConnectionState("server_error")
            errorMessage = error.localizedDescription
            showError = true
            sessions = []
            diagnostics = nil
        } catch {
            connectionState = .serverError(error.localizedDescription)
            updateActiveServerConnectionState("server_error")
            errorMessage = error.localizedDescription
            showError = true
            sessions = []
            diagnostics = nil
        }
    }

    var canCreateSession: Bool {
        switch connectionState {
        case .ready, .readyNoSessions:
            return true
        default:
            return false
        }
    }

    func createSession(name: String, cwd: String) async -> Bool {
        guard canCreateSession else {
            return false
        }
        do {
            try await api.createSession(name: name, cwd: cwd)
            await loadSessions()
            return true
        } catch let error as APIError {
            if case .unauthorized = error {
                connectionState = .unauthorized
                updateActiveServerConnectionState("unauthorized")
                return false
            }
            if case .networkError(let underlying) = error {
                connectionState = .unreachable(underlying.localizedDescription)
                updateActiveServerConnectionState("unreachable")
                errorMessage = underlying.localizedDescription
                showError = true
                return false
            }
            connectionState = .serverError(error.localizedDescription)
            updateActiveServerConnectionState("server_error")
            errorMessage = error.localizedDescription
            showError = true
            return false
        } catch {
            connectionState = .serverError(error.localizedDescription)
            updateActiveServerConnectionState("server_error")
            errorMessage = error.localizedDescription
            showError = true
            return false
        }
    }

    func deletePane(target: String) async {
        guard canCreateSession else {
            return
        }
        do {
            try await api.deletePane(target: target)
            await loadSessions()
        } catch let error as APIError {
            if case .unauthorized = error {
                connectionState = .unauthorized
                updateActiveServerConnectionState("unauthorized")
                return
            }
            connectionState = .serverError(error.localizedDescription)
            updateActiveServerConnectionState("server_error")
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            connectionState = .serverError(error.localizedDescription)
            updateActiveServerConnectionState("server_error")
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func updateActiveServerConnectionState(_ state: String) {
        guard var active = ServerConfigManager.shared.activeServer else { return }
        active.lastConnectionState = state
        active.lastVerifiedAt = Date()
        ServerConfigManager.shared.updateServer(active)
    }
}

#Preview {
    SessionListView()
}
