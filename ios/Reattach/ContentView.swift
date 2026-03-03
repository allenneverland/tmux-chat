//
//  ContentView.swift
//  Reattach
//

import SwiftUI

struct ContentView: View {
    var api = ReattachAPI.shared
    @State private var configManager = ServerConfigManager.shared
    @State private var isCheckingAuth = true
    @State private var showCloudflareAuth = false
    @State private var showManualSetup = false

    var body: some View {
        Group {
            if !configManager.isConfigured {
                SetupView(onTryDemo: { configManager.enableDemoMode() })
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
            case .cloudflareExpired:
                showCloudflareAuth = true
            case .deviceTokenInvalid:
                showManualSetup = true
            }
        }
        .fullScreenCover(isPresented: $showCloudflareAuth) {
            CloudflareAuthWebView(api: api, isPresented: $showCloudflareAuth)
                .onDisappear {
                    api.clearAuthError()
                    NotificationCenter.default.post(name: .authenticationRestored, object: nil)
                }
        }
        .sheet(isPresented: $showManualSetup) {
            ManualServerSetupView()
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
            AppDelegate.shared?.registerDeviceTokenWithServer()
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
    @State private var showManualSetup = false
    var onTryDemo: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("Reattach")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Control your tmux sessions remotely")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                showManualSetup = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("Add Server Manually")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Text("Paste credentials from reattachd devices issue --name <name> --json")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                onTryDemo()
            } label: {
                Text("Try Demo Mode")
                    .foregroundStyle(.tint)
            }
            .padding(.top, 8)

            Spacer()
        }
        .sheet(isPresented: $showManualSetup) {
            ManualServerSetupView()
        }
    }
}

#Preview("Content") {
    ContentView()
}

#Preview("Setup") {
    SetupView(onTryDemo: {})
}
