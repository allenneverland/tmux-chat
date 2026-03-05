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

    var serverToRepair: ServerConfig? = nil
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
                    Text("TmuxChat connects over SSH, installs host-agent, configures Bash auto-notify for long-running commands, pairs notifications, and saves credentials. Use the same SSH user that owns your tmux sessions.")
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
                    serverURL = serverToRepair?.serverURL ?? defaultServerURL()
                }
                if serverName.isEmpty, let serverToRepair {
                    serverName = serverToRepair.serverName
                }
                if sshHost.isEmpty, let host = URL(string: serverURL)?.host {
                    sshHost = host
                }
                applyStoredSSHCredential()
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

        let success = await coordinator.start(
            input: input,
            apnsToken: AppDelegate.shared?.deviceToken,
            replacingServerId: serverToRepair?.id
        )
        if success {
            onCompleted?()
            dismiss()
            return
        }
        showError = true
    }

    private func defaultServerURL() -> String {
        ServerConfigManager.shared.activeServer?.serverURL ?? ""
    }

    private func applyStoredSSHCredential() {
        guard sshHost.isEmpty || sshUsername.isEmpty else { return }

        guard let credentialId = serverToRepair?.sshCredentialId ?? ServerConfigManager.shared.activeServer?.sshCredentialId else {
            return
        }
        guard let stored = try? SSHCredentialStore.shared.load(id: credentialId) else {
            return
        }

        if sshHost.isEmpty {
            sshHost = stored.host
        }
        if sshPort == "22" {
            sshPort = String(stored.port)
        }
        if sshUsername.isEmpty {
            sshUsername = stored.username
        }
        switch stored.secret {
        case .password(let value):
            authMode = .password
            if password.isEmpty {
                password = value
            }
        case .privateKey(let key, let passphrase):
            authMode = .privateKey
            if privateKey.isEmpty {
                privateKey = key
            }
            if privateKeyPassphrase.isEmpty {
                privateKeyPassphrase = passphrase ?? ""
            }
        }
    }
}

#Preview {
    SSHOnboardingView()
}
