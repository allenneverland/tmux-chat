//
//  SSHOnboardingView.swift
//  TmuxChat
//

import SwiftUI

struct SSHOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = SSHOnboardingCoordinator()

    @State private var serverURL = ""
    @State private var serverName = ""
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUsername = ""
    @State private var authMode: SSHAuthenticationMode = .password
    @State private var password = ""
    @State private var privateKey = ""
    @State private var privateKeyPassphrase = ""
    @State private var showError = false

    var onCompleted: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section("Control Plane") {
                    TextField("https://your-server.example.com", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Server name", text: $serverName)
                }

                Section("SSH Host") {
                    TextField("Host (IP or domain)", text: $sshHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $sshPort)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $sshUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMode) {
                        Text("Password").tag(SSHAuthenticationMode.password)
                        Text("Private Key").tag(SSHAuthenticationMode.privateKey)
                    }
                    .pickerStyle(.segmented)

                    if authMode == .password {
                        SecureField("Password", text: $password)
                    } else {
                        TextEditor(text: $privateKey)
                            .frame(minHeight: 140)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Private key passphrase (optional)", text: $privateKeyPassphrase)
                        Text("Supported formats: PEM-encoded ECDSA, or unencrypted OpenSSH Ed25519.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task {
                            await submit()
                        }
                    } label: {
                        HStack {
                            if coordinator.isRunning {
                                ProgressView()
                            }
                            Text(coordinator.isRunning ? coordinator.stepLabel : "Connect and Install")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(coordinator.isRunning)
                } footer: {
                    Text("TmuxChat will connect over SSH, install host-agent, pair notifications, and save server credentials.")
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(coordinator.isRunning)
                }
            }
            .alert("Setup Failed", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(coordinator.errorMessage ?? "Unknown error")
            }
            .onAppear {
                if serverURL.isEmpty {
                    serverURL = defaultServerURL()
                }
                if sshHost.isEmpty, let host = URL(string: serverURL)?.host {
                    sshHost = host
                }
                if sshUsername.isEmpty {
                    sshUsername = "root"
                }
            }
        }
    }

    private func submit() async {
        guard let port = UInt16(sshPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            coordinator.errorMessage = "SSH port must be a valid number"
            showError = true
            return
        }

        let input = SSHOnboardingInput(
            serverURL: serverURL,
            serverName: serverName,
            sshHost: sshHost,
            sshPort: port,
            sshUsername: sshUsername,
            authMode: authMode,
            password: password,
            privateKey: privateKey,
            privateKeyPassphrase: privateKeyPassphrase
        )

        let success = await coordinator.start(input: input, apnsToken: AppDelegate.shared?.deviceToken)
        if success {
            NotificationCenter.default.post(name: .authenticationRestored, object: nil)
            onCompleted?()
            dismiss()
            return
        }
        showError = true
    }

    private func defaultServerURL() -> String {
        ServerConfigManager.shared.activeServer?.serverURL ?? ""
    }
}

#Preview {
    SSHOnboardingView()
}
