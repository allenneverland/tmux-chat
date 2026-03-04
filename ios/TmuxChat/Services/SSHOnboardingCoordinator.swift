//
//  SSHOnboardingCoordinator.swift
//  TmuxChat
//

import Foundation
import Observation
import UIKit

struct SSHOnboardingInput {
    let serverURL: String
    let serverName: String
    let sshHost: String
    let sshPort: UInt16
    let sshUsername: String
    let authMode: SSHAuthenticationMode
    let password: String
    let privateKey: String
    let privateKeyPassphrase: String
}

enum SSHOnboardingStep: String {
    case idle
    case validatingInput
    case connectingSSH
    case verifyingTmuxChatd
    case detectingPlatform
    case installingHostAgent
    case issuingControlToken
    case startingPairing
    case pairingHostAgent
    case registeringDevice
    case savingConfiguration
    case verifyingControlPlane
    case completed
    case failed
}

@MainActor
@Observable
final class SSHOnboardingCoordinator {
    var isRunning = false
    var step: SSHOnboardingStep = .idle
    var errorMessage: String?

    @ObservationIgnored
    private let api: TmuxChatAPI
    @ObservationIgnored
    private let sshExecutor: SSHCommandExecuting
    @ObservationIgnored
    private let installer: HostAgentInstaller

    init(api: TmuxChatAPI, sshExecutor: SSHCommandExecuting) {
        self.api = api
        self.sshExecutor = sshExecutor
        self.installer = HostAgentInstaller(sshExecutor: sshExecutor)
    }

    convenience init() {
        self.init(api: .shared, sshExecutor: SSHCommandExecutor())
    }

    var stepLabel: String {
        switch step {
        case .idle:
            return "Ready"
        case .validatingInput:
            return "Validating input"
        case .connectingSSH:
            return "Connecting over SSH"
        case .verifyingTmuxChatd:
            return "Checking tmux-chatd on host"
        case .detectingPlatform:
            return "Detecting host platform"
        case .installingHostAgent:
            return "Installing host-agent"
        case .issuingControlToken:
            return "Issuing control token"
        case .startingPairing:
            return "Starting push pairing"
        case .pairingHostAgent:
            return "Pairing host-agent"
        case .registeringDevice:
            return "Registering APNs device"
        case .savingConfiguration:
            return "Saving server configuration"
        case .verifyingControlPlane:
            return "Verifying tmux control API"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    func start(input: SSHOnboardingInput, apnsToken: String?) async -> Bool {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            step = .validatingInput
            let normalizedURL = try normalizeServerURL(input.serverURL)
            let finalServerName = normalizedServerName(input.serverName, fallbackURL: normalizedURL)
            let pushServerURL = try validatePushServerBaseURL()
            let apnsToken = try validatedAPNSToken(apnsToken)
            let connectionSpec = try makeConnectionSpec(from: input)

            step = .connectingSSH
            _ = try await sshExecutor.run(command: "echo ssh-ok", on: connectionSpec)

            step = .verifyingTmuxChatd
            do {
                try await installer.ensureTmuxChatdInstalled(on: connectionSpec)
            } catch {
                throw HostAgentInstallerError.missingTmuxChatd
            }

            step = .detectingPlatform
            let platform = try await installer.detectPlatform(on: connectionSpec)

            step = .installingHostAgent
            try await installer.install(
                on: connectionSpec,
                pushServerBaseURL: pushServerURL,
                releaseAssetName: platform.releaseAssetName
            )

            step = .issuingControlToken
            let issued = try await issueDeviceCredentials(on: connectionSpec)

            step = .startingPairing
            let pairing = try await api.startPairing(
                deviceId: issued.deviceId,
                deviceName: UIDevice.current.name,
                serverName: finalServerName
            )

            step = .pairingHostAgent
            _ = try await installer.pair(
                on: connectionSpec,
                pairingToken: pairing.pairingToken,
                pushServerBaseURL: pushServerURL
            )

            step = .registeringDevice
            let registration = try await api.registerAPNsDevice(
                token: apnsToken,
                deviceId: issued.deviceId,
                serverName: finalServerName,
                deviceRegisterToken: pairing.deviceRegisterToken
            )

            step = .savingConfiguration
            if let existing = ServerConfigManager.shared.servers.first(where: { $0.deviceId == issued.deviceId }) {
                SSHCredentialStore.shared.delete(id: existing.sshCredentialId)
            }
            let credentialId = try SSHCredentialStore.shared.save(connectionSpec)
            let config = ServerConfig(
                serverURL: normalizedURL,
                controlToken: issued.deviceToken,
                deviceId: issued.deviceId,
                deviceName: issued.deviceName,
                serverName: finalServerName,
                deviceApiToken: registration.deviceApiToken,
                sshCredentialId: credentialId,
                needsPushRebind: false,
                registeredAt: Date()
            )
            ServerConfigManager.shared.addServer(config)
            ServerConfigManager.shared.setActiveServer(config.id)

            step = .verifyingControlPlane
            _ = try await api.listSessions()

            step = .completed
            return true
        } catch {
            step = .failed
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func makeConnectionSpec(from input: SSHOnboardingInput) throws -> SSHConnectionSpec {
        let host = input.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw APIError.serverError("SSH host is required")
        }
        let username = input.sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw APIError.serverError("SSH username is required")
        }
        let secret: SSHAuthenticationSecret
        switch input.authMode {
        case .password:
            let password = input.password.trimmingCharacters(in: .newlines)
            guard !password.isEmpty else {
                throw APIError.serverError("SSH password is required")
            }
            secret = .password(password)
        case .privateKey:
            let key = input.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw APIError.serverError("SSH private key is required")
            }
            let passphrase = input.privateKeyPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            secret = .privateKey(key: key, passphrase: passphrase.isEmpty ? nil : passphrase)
        }
        return SSHConnectionSpec(
            host: host,
            port: input.sshPort,
            username: username,
            secret: secret
        )
    }

    private func issueDeviceCredentials(on connection: SSHConnectionSpec) async throws -> IssuedDeviceCredentials {
        let rawDeviceName = UIDevice.current.name
        let command = "tmux-chatd devices issue --name \(shellQuote(rawDeviceName)) --json"
        let result = try await sshExecutor.run(command: command, on: connection)
        return try decodeJSONFromOutput(result.stdout, as: IssuedDeviceCredentials.self)
    }

    private func decodeJSONFromOutput<T: Decodable>(_ output: String, as type: T.Type) throws -> T {
        if let directData = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let value = try? JSONDecoder().decode(type, from: directData) {
            return value
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode(type, from: data) {
                return decoded
            }
        }

        throw APIError.decodingError(NSError(domain: "SSHOutput", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Unable to parse JSON from remote command output"
        ]))
    }

    private func validatePushServerBaseURL() throws -> String {
        let value = api.pushServerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw APIError.serverError("Push server base URL is not configured")
        }
        return value
    }

    private func validatedAPNSToken(_ token: String?) throws -> String {
        guard let token else {
            throw APIError.serverError("Notifications are not ready. Allow notifications and retry.")
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("APNs token is empty")
        }
        return trimmed
    }

    private func normalizeServerURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Server URL is required")
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            throw APIError.serverError("Enter a valid http(s) server URL")
        }

        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private func normalizedServerName(_ raw: String, fallbackURL: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return URL(string: fallbackURL)?.host ?? fallbackURL
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
