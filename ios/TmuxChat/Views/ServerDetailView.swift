//
//  ServerDetailView.swift
//  TmuxChat
//

import SwiftUI

struct ServerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configManager = ServerConfigManager.shared

    let server: ServerConfig

    @State private var serverName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var showRepairOnboarding = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Server Name", text: $serverName)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("URL", value: server.serverURL)
            } header: {
                Text("Server")
            }

            Section("Notifications") {
                NavigationLink {
                    NotificationMutesView(server: server)
                } label: {
                    Label("Mute Settings", systemImage: "bell.slash")
                }
            }

            Section("Input") {
                NavigationLink {
                    ShortcutSettingsView()
                } label: {
                    Label("Shortcut Settings", systemImage: "keyboard")
                }
            }

            Section("Maintenance") {
                Button {
                    showRepairOnboarding = true
                } label: {
                    Label("Update & Re-pair Server", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete Server")
                        Spacer()
                    }
                }
            }
        }
        .sheet(isPresented: $showRepairOnboarding) {
            SSHOnboardingView(serverToRepair: server) {
                NotificationCenter.default.post(name: .authenticationRestored, object: nil)
                dismiss()
            }
        }
        .confirmationDialog("Delete Server", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                configManager.removeServer(server.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \(server.serverName)?")
        }
        .navigationTitle("Server Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveChanges()
                    dismiss()
                }
            }
        }
        .onAppear {
            serverName = server.serverName
        }
    }

    private func saveChanges() {
        guard var updatedServer = configManager.servers.first(where: { $0.id == server.id }) else {
            return
        }
        updatedServer.serverName = serverName
        configManager.updateServer(updatedServer)
    }
}

#Preview {
    NavigationStack {
        ServerDetailView(server: ServerConfig(
            serverURL: "https://example.com",
            controlToken: "token",
            deviceId: "device-id",
            deviceName: "My Mac",
            serverName: "Home Server",
            registeredAt: Date()
        ))
    }
}
