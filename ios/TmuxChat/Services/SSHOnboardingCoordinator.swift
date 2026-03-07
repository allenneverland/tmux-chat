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
    case installingTmuxChatd
    case startingTmuxChatd
    case detectingPlatform
    case installingHostAgent
    case issuingControlToken
    case startingPairing
    case pairingHostAgent
    case verifyingHostAgentNotifications
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
        case .installingTmuxChatd:
            return "Installing tmux-chatd"
        case .startingTmuxChatd:
            return "Starting tmux-chatd"
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
        case .verifyingHostAgentNotifications:
            return "Verifying host-agent notifications"
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

    func start(input: SSHOnboardingInput, apnsToken: String?, replacingServerId: String? = nil) async -> Bool {
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
            try await validateSSHUser(on: connectionSpec)

            step = .verifyingTmuxChatd
            _ = try await sshExecutor.run(
                command: "/bin/sh -c \(shellQuote("command -v tmux-chatd >/dev/null 2>&1 || [ -x \"$HOME/.local/bin/tmux-chatd\" ] || true"))",
                on: connectionSpec
            )

            step = .installingTmuxChatd
            let tmuxChatdExecutable = try await installer.ensureTmuxChatdInstalled(on: connectionSpec)

            step = .startingTmuxChatd
            try await installer.ensureTmuxChatdRunning(
                on: connectionSpec,
                executable: tmuxChatdExecutable,
                pushServerBaseURL: pushServerURL,
                expectedUsername: connectionSpec.username
            )

            step = .detectingPlatform
            let platform = try await installer.detectPlatform(on: connectionSpec)

            step = .installingHostAgent
            try await installer.install(
                on: connectionSpec,
                pushServerBaseURL: pushServerURL,
                releaseAssetName: platform.releaseAssetName
            )

            step = .issuingControlToken
            let issued = try await issueDeviceCredentials(
                on: connectionSpec,
                tmuxChatdExecutable: tmuxChatdExecutable
            )

            let provisionalConfig = ServerConfig(
                serverURL: normalizedURL,
                controlToken: issued.deviceToken,
                deviceId: issued.deviceId,
                deviceName: issued.deviceName,
                serverName: finalServerName,
                deviceApiToken: nil,
                sshCredentialId: nil,
                sshUsername: connectionSpec.username,
                needsPushRebind: false,
                registeredAt: Date()
            )

            step = .verifyingControlPlane
            try await verifyControlPlaneContractOnHostLoopback(
                on: connectionSpec,
                deviceToken: issued.deviceToken
            )
            let verification = try await verifyControlPlaneContractFromClient(server: provisionalConfig)
            guard verification.diagnostics.daemonUser == connectionSpec.username else {
                throw APIError.serverError(
                    "Control URL points to tmux-chatd user \(verification.diagnostics.daemonUser), but SSH onboarding user is \(connectionSpec.username). Verify reverse-proxy/tunnel routing and reconnect with the tmux owner account."
                )
            }

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

            step = .verifyingHostAgentNotifications
            try await installer.verifyHostAgentReadiness(on: connectionSpec)

            step = .registeringDevice
            let registration = try await api.registerAPNsDevice(
                token: apnsToken,
                deviceId: issued.deviceId,
                serverName: finalServerName,
                deviceRegisterToken: pairing.deviceRegisterToken
            )

            step = .savingConfiguration
            let replacingServer = replacingServerId.flatMap { serverId in
                ServerConfigManager.shared.servers.first { $0.id == serverId }
            }
            let existingByDeviceId = ServerConfigManager.shared.servers.first(where: { $0.deviceId == issued.deviceId })
            let credentialId = try SSHCredentialStore.shared.save(connectionSpec)

            if let replacingServer {
                ServerConfigManager.shared.removeServer(replacingServer.id)
            }

            var config = provisionalConfig
            config.deviceApiToken = registration.deviceApiToken
            config.sshCredentialId = credentialId
            config.sshUsername = connectionSpec.username
            config.lastVerifiedDaemonUser = verification.diagnostics.daemonUser
            config.lastConnectionState = verification.sessions.isEmpty ? "ready_no_sessions" : "ready"
            config.lastVerifiedAt = Date()

            guard ServerConfigManager.shared.addServer(config) else {
                if let replacingServer {
                    _ = ServerConfigManager.shared.addServer(replacingServer)
                    ServerConfigManager.shared.setActiveServer(replacingServer.id)
                }
                SSHCredentialStore.shared.delete(id: credentialId)
                throw APIError.serverError(
                    "Cannot save server: reached server limit. Delete another server or upgrade, then retry."
                )
            }

            if let replacingServer {
                SSHCredentialStore.shared.delete(id: replacingServer.sshCredentialId)
            } else if let existingByDeviceId {
                SSHCredentialStore.shared.delete(id: existingByDeviceId.sshCredentialId)
            }
            ServerConfigManager.shared.setActiveServer(config.id)

            step = .completed
            return true
        } catch {
            let failedAt = stepLabel
            step = .failed
            errorMessage = "[\(failedAt)] \(error.localizedDescription)"
            return false
        }
    }

    private func makeConnectionSpec(from input: SSHOnboardingInput) throws -> SSHConnectionSpec {
        let hostInput = input.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostInput.isEmpty else {
            throw APIError.serverError("SSH host is required")
        }
        let host = try validateSSHHost(hostInput)

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

    private func validateSSHHost(_ value: String) throws -> String {
        if value.contains("://") {
            throw APIError.serverError("SSH host should be hostname/IP only, without http:// or https://")
        }

        if value.contains("@") {
            throw APIError.serverError("SSH host should not include username. Fill username in the Username field.")
        }

        if value.contains("/") || value.contains("?") || value.contains("#") {
            throw APIError.serverError("SSH host should not include URL path or query")
        }

        if let index = value.lastIndex(of: ":"),
           !value.hasPrefix("["),
           !value.contains("::") {
            let suffix = value[value.index(after: index)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                throw APIError.serverError("SSH host should not include :port. Use the Port field instead.")
            }
        }

        if value.hasPrefix("["),
           value.hasSuffix("]"),
           value.count > 2 {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    private func validateSSHUser(on connection: SSHConnectionSpec) async throws {
        let result = try await sshExecutor.run(command: "/bin/sh -c \(shellQuote("id -un"))", on: connection)
        let remoteUser = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteUser.isEmpty else {
            throw APIError.serverError("Unable to determine remote SSH user")
        }
        guard remoteUser == connection.username else {
            throw APIError.serverError(
                "SSH user mismatch. Connected as \(remoteUser), but form username is \(connection.username)."
            )
        }
    }

    private func issueDeviceCredentials(
        on connection: SSHConnectionSpec,
        tmuxChatdExecutable: String
    ) async throws -> IssuedDeviceCredentials {
        let rawDeviceName = UIDevice.current.name
        let command = "\(shellQuote(tmuxChatdExecutable)) devices issue --name \(shellQuote(rawDeviceName)) --json"
        let result = try await sshExecutor.run(command: "/bin/sh -c \(shellQuote(command))", on: connection)
        return try decodeJSONFromOutput(result.stdout, as: IssuedDeviceCredentials.self)
    }

    private func verifyControlPlaneContractOnHostLoopback(
        on connection: SSHConnectionSpec,
        deviceToken: String
    ) async throws {
        let script = """
        set -eu

        TOKEN=\(shellQuote(deviceToken))
        BASE_URL="http://127.0.0.1:8787"

        if ! command -v curl >/dev/null 2>&1; then
          echo "loopback_missing_curl" >&2
          exit 1
        fi

        CAPS_JSON="$(curl -fsS "$BASE_URL/capabilities")"

        if command -v jq >/dev/null 2>&1; then
          echo "$CAPS_JSON" \
            | jq -e '.capabilities_schema_version >= 3 and .features.shortcut_keys == true and .endpoints.pane_key == true and .endpoints.pane_key_probe == true' >/dev/null \
            || { echo "loopback_capabilities_contract_mismatch" >&2; exit 1; }
        else
          echo "$CAPS_JSON" | grep -Eq '"capabilities_schema_version"[[:space:]]*:[[:space:]]*[3-9][0-9]*' || { echo "loopback_capabilities_schema_too_old" >&2; exit 1; }
          echo "$CAPS_JSON" | grep -Eq '"shortcut_keys"[[:space:]]*:[[:space:]]*true' || { echo "loopback_capabilities_shortcut_keys_missing" >&2; exit 1; }
          echo "$CAPS_JSON" | grep -Eq '"pane_key"[[:space:]]*:[[:space:]]*true' || { echo "loopback_capabilities_pane_key_missing" >&2; exit 1; }
          echo "$CAPS_JSON" | grep -Eq '"pane_key_probe"[[:space:]]*:[[:space:]]*true' || { echo "loopback_capabilities_pane_key_probe_missing" >&2; exit 1; }
        fi

        curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE_URL/diagnostics" >/dev/null

        STATUS="$(curl -sS -o /dev/null -w "%{http_code}" \
          -X POST \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          "$BASE_URL/panes/shortcut-probe/key?probe=true" \
          -d '{"key":"Enter"}')"
        [ "$STATUS" = "204" ] || { echo "loopback_probe_http_${STATUS}" >&2; exit 1; }
        """

        do {
            _ = try await sshExecutor.run(command: "/bin/sh -c \(shellQuote(script))", on: connection)
        } catch {
            throw mapLoopbackControlPlaneError(error)
        }
    }

    private func verifyControlPlaneContractFromClient(
        server: ServerConfig
    ) async throws -> (sessions: [Session], diagnostics: DaemonDiagnosticsResponse) {
        do {
            let capabilities = try await api.getCapabilities(server: server, forceRefresh: true)
            guard capabilities.supportsRequiredShortcutContract else {
                throw APIError.serverError(
                    requiredShortcutContractFailureMessage(
                        scope: "Control URL \(server.serverURL)",
                        capabilities: capabilities
                    )
                )
            }

            let sessions = try await api.listSessions(for: server)
            let probeTarget = sessions
                .flatMap(\.windows)
                .flatMap(\.panes)
                .first?
                .target ?? "shortcut-probe"
            try await api.probeShortcutKeyEndpoint(target: probeTarget, server: server)
            let diagnostics = try await api.getDiagnostics(server: server)

            return (sessions, diagnostics)
        } catch {
            throw mapExternalControlPlaneError(error, serverURL: server.serverURL)
        }
    }

    private func requiredShortcutContractFailureMessage(
        scope: String,
        capabilities: DaemonCapabilitiesResponse
    ) -> String {
        let schema = capabilities.capabilitiesSchemaVersion.map(String.init) ?? "nil"
        let shortcutKeys = capabilities.features?.shortcutKeys.map { $0 ? "true" : "false" } ?? "nil"
        let paneKey = capabilities.endpoints.paneKey.map { $0 ? "true" : "false" } ?? "nil"
        let paneKeyProbe = capabilities.endpoints.paneKeyProbe.map { $0 ? "true" : "false" } ?? "nil"
        return
            "\(scope) does not satisfy required control-plane contract (required: schema>=3, shortcut_keys=true, pane_key=true, pane_key_probe=true; got: schema=\(schema), shortcut_keys=\(shortcutKeys), pane_key=\(paneKey), pane_key_probe=\(paneKeyProbe)). Upgrade host tmux-chatd and verify reverse-proxy/tunnel routing."
    }

    private func mapLoopbackControlPlaneError(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        guard case .commandFailed(_, let stderr) = error as? SSHCommandExecutorError else {
            return APIError.serverError(
                "Host loopback control-plane verification failed. \(error.localizedDescription)"
            )
        }

        let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.contains("loopback_missing_curl") {
            return APIError.serverError(
                "Host loopback control-plane verification failed: `curl` is missing on remote host."
            )
        }
        if details.contains("loopback_capabilities_contract_mismatch") {
            return APIError.serverError(
                "Host loopback tmux-chatd does not satisfy required control-plane contract (schema>=3 + pane_key_probe). Details: \(details)"
            )
        }
        if details.contains("loopback_probe_http_") {
            return APIError.serverError(
                "Host loopback shortcut probe route is not healthy (`POST /panes/{target}/key?probe=true` must return 204). Details: \(details)"
            )
        }
        if details.isEmpty {
            return APIError.serverError("Host loopback control-plane verification failed.")
        }
        return APIError.serverError("Host loopback control-plane verification failed: \(details)")
    }

    private func mapExternalControlPlaneError(_ error: Error, serverURL: String) -> APIError {
        guard let apiError = error as? APIError else {
            return APIError.serverError(
                "External control-plane verification failed for \(serverURL): \(error.localizedDescription)"
            )
        }

        switch apiError {
        case .serverError:
            return apiError
        case .unauthorized:
            return APIError.serverError(
                "Control URL \(serverURL) rejected the newly issued token. This usually means URL/route points to a different tmux-chatd host than the SSH target."
            )
        case .networkError(let underlying):
            return APIError.serverError(
                "Control URL \(serverURL) is unreachable from this iOS device. \(underlying.localizedDescription)"
            )
        case .httpError(let statusCode, let path, let code, _):
            if statusCode == 404,
               path == "/capabilities" || path == "/diagnostics" || path == "/sessions" {
                return APIError.serverError(
                    "Control URL \(serverURL) is missing required endpoints (\(path)). Upgrade tmux-chatd or fix reverse-proxy/tunnel route mapping."
                )
            }
            if statusCode == 404, path.contains("/panes/"), path.contains("/key") {
                return APIError.serverError(
                    "Control URL \(serverURL) has shortcut route mismatch: `POST /panes/*/key?probe=true` returned 404. Fix reverse-proxy/tunnel method+path routing."
                )
            }
            if statusCode == 400, code == "missing_key_payload" || code == "invalid_key_token" {
                return APIError.serverError(
                    "Control URL \(serverURL) is running an incompatible key endpoint contract. Upgrade host tmux-chatd and retry."
                )
            }
            return APIError.serverError(
                "External control-plane verification failed for \(serverURL): HTTP \(statusCode) at \(path)."
            )
        case .decodingError:
            return APIError.serverError(
                "Control URL \(serverURL) returned malformed control-plane payload. Upgrade tmux-chatd and verify no proxy is rewriting JSON responses."
            )
        case .invalidURL:
            return APIError.serverError("Control URL \(serverURL) is invalid.")
        }
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
            throw APIError.serverError("Push server base URL is not configured or invalid. In Config.xcconfig, use https:/$()/host format.")
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            throw APIError.serverError("Push server base URL is invalid: \(value)")
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

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host != nil else {
            throw APIError.serverError("Enter a valid http(s) server URL")
        }

        let rawPath = components.percentEncodedPath
        let normalizedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedPath == "/healthz" || normalizedPath == "/healthz/" || normalizedPath == "/" {
            components.percentEncodedPath = ""
        } else if !normalizedPath.isEmpty {
            throw APIError.serverError("Server URL should not include a path. Use only scheme://host[:port]")
        }

        if components.query != nil || components.fragment != nil {
            throw APIError.serverError("Server URL should not include query or fragment")
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let normalized = components.string else {
            throw APIError.serverError("Enter a valid http(s) server URL")
        }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
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
