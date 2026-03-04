//
//  ContentView.swift
//  TmuxChat
//

import SwiftUI

struct ContentView: View {
    var api = TmuxChatAPI.shared
    @State private var configManager = ServerConfigManager.shared
    @State private var isCheckingAuth = true
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if !configManager.isConfigured {
                SetupView {
                    configManager.enableDemoMode()
                }
            } else if isCheckingAuth && !configManager.isDemoMode {
                ProgressView("Connecting...")
            } else {
                SessionListView()
            }
        }
        .task {
            if configManager.isConfigured {
                await checkAuthentication()
            }
        }
        .onChange(of: configManager.isConfigured) { _, isConfigured in
            if isConfigured {
                Task {
                    await checkAuthentication()
                }
            }
        }
        .onChange(of: api.authErrorType) { _, errorType in
            guard let errorType else { return }
            switch errorType {
            case .deviceTokenInvalid:
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            SSHOnboardingView {
                Task {
                    await checkAuthentication()
                }
            }
            .onDisappear {
                api.clearAuthError()
                NotificationCenter.default.post(name: .authenticationRestored, object: nil)
            }
        }
    }

    private func checkAuthentication() async {
        do {
            try await withTimeout(seconds: 5) {
                _ = try await api.listSessions()
            }
        } catch {
            print("Auth check failed: \(error)")
        }
        isCheckingAuth = false
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

struct SetupView: View {
    @State private var showOnboarding = false
    var onTryDemo: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("TmuxChat")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Control your tmux sessions remotely")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                showOnboarding = true
            } label: {
                HStack {
                    Image(systemName: "lock.shield")
                    Text("Add Server via SSH")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Text("App connects over SSH, installs host-agent, and configures notifications automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                onTryDemo()
            } label: {
                Text("Try Demo Mode")
                    .foregroundStyle(.tint)
            }
            .padding(.top, 8)

            Spacer()
        }
        .sheet(isPresented: $showOnboarding) {
            SSHOnboardingView()
        }
    }
}

#Preview("Content") {
    ContentView()
}

#Preview("Setup") {
    SetupView(onTryDemo: {})
}
