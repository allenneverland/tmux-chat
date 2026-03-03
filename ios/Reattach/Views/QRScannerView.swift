//
//  QRScannerView.swift
//  Reattach
//

import SwiftUI
import UIKit

private struct IssuedDeviceCredentials: Decodable {
    let deviceId: String
    let deviceName: String
    let deviceToken: String

    private enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case deviceToken = "device_token"
    }
}

struct ManualServerSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var serverName = ""
    @State private var issueJSON = ""
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://your-server.example.com", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Server name", text: $serverName)
                }

                Section("Device Credentials JSON") {
                    TextEditor(text: $issueJSON)
                        .frame(minHeight: 140)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Generate from host: reattachd devices issue --name \"\(UIDevice.current.name)\" --json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Add Server") {
                        addServer()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Unable to Add Server", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private func addServer() {
        do {
            let normalizedURL = try normalizedServerURL(serverURL)
            let credentials = try parseCredentials(issueJSON)
            let finalServerName = serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (URL(string: normalizedURL)?.host ?? normalizedURL)
                : serverName.trimmingCharacters(in: .whitespacesAndNewlines)

            let serverConfig = ServerConfig(
                serverURL: normalizedURL,
                deviceToken: credentials.deviceToken,
                deviceId: credentials.deviceId,
                deviceName: credentials.deviceName,
                serverName: finalServerName,
                registeredAt: Date()
            )

            ServerConfigManager.shared.addServer(serverConfig)
            ServerConfigManager.shared.setActiveServer(serverConfig.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func normalizedServerURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ManualSetupError.invalidServerURL("Server URL is required")
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            throw ManualSetupError.invalidServerURL("Enter a valid http(s) server URL")
        }

        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private func parseCredentials(_ rawJSON: String) throws -> IssuedDeviceCredentials {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ManualSetupError.invalidJSON("Device credentials JSON is required")
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw ManualSetupError.invalidJSON("Device credentials JSON is not UTF-8")
        }

        let decoded = try JSONDecoder().decode(IssuedDeviceCredentials.self, from: data)
        guard !decoded.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManualSetupError.invalidJSON("device_id cannot be empty")
        }
        guard !decoded.deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManualSetupError.invalidJSON("device_token cannot be empty")
        }
        return decoded
    }
}

private enum ManualSetupError: LocalizedError {
    case invalidServerURL(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL(let message), .invalidJSON(let message):
            return message
        }
    }
}

#Preview {
    ManualServerSetupView()
}
