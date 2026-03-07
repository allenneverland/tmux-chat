//
//  TmuxChatAPI.swift
//  TmuxChat
//

import Foundation
import Observation
import UIKit

enum AuthErrorType {
    case deviceTokenInvalid
}

enum APIError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case serverError(String)
    case httpError(statusCode: Int, path: String, code: String?, message: String?)
    case decodingError(Error)
    case unauthorized(AuthErrorType)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .httpError(let statusCode, let path, _, let message):
            if let message, !message.isEmpty {
                return "HTTP \(statusCode) at \(path): \(message)"
            }
            return "HTTP \(statusCode) at \(path)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .unauthorized(let type):
            switch type {
            case .deviceTokenInvalid:
                return "Device credentials invalid - please re-add this server"
            }
        }
    }
}

@MainActor
@Observable
class TmuxChatAPI {
    static let shared = TmuxChatAPI()

    var isAuthenticated: Bool = false
    var authErrorType: AuthErrorType?

    var baseURL: String {
        ServerConfigManager.shared.activeServer?.serverURL ?? ""
    }

    var pushServerBaseURL: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PushServerBaseURL") as? String else {
            return ""
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") {
            return ""
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return ""
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    var controlToken: String? {
        ServerConfigManager.shared.activeServer?.controlToken
    }

    var deviceApiToken: String? {
        ServerConfigManager.shared.activeServer?.deviceApiToken
    }

    var isConfigured: Bool {
        ServerConfigManager.shared.isConfigured
    }

    var isDemoMode: Bool {
        ServerConfigManager.shared.isDemoMode
    }

    private let session: URLSession
    private var demoInputHistory: [String: [String]] = [:]
    private var capabilitiesCache: [String: DaemonCapabilitiesResponse] = [:]

    init() {
        self.session = URLSession(configuration: .default)
    }

    func clearAuthError() {
        authErrorType = nil
    }

    func listSessions() async throws -> [Session] {
        if isDemoMode {
            return Self.demoSessions
        }
        let data = try await request(path: "/sessions", method: "GET")
        return try JSONDecoder().decode([Session].self, from: data)
    }

    func listSessions(for server: ServerConfig) async throws -> [Session] {
        if isDemoMode {
            return Self.demoSessions
        }
        let data = try await request(path: "/sessions", method: "GET", server: server)
        return try JSONDecoder().decode([Session].self, from: data)
    }

    func getCapabilities(server: ServerConfig? = nil, forceRefresh: Bool = false) async throws -> DaemonCapabilitiesResponse {
        if isDemoMode {
            return Self.demoCapabilities
        }

        let targetServer = server ?? ServerConfigManager.shared.activeServer
        let cacheKey = capabilitiesCacheKey(for: targetServer)

        if !forceRefresh, let cacheKey, let cached = capabilitiesCache[cacheKey] {
            return cached
        }

        let data = try await request(path: "/capabilities", method: "GET", server: targetServer)
        let capabilities = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: data)
        if let cacheKey {
            capabilitiesCache[cacheKey] = capabilities
        }
        return capabilities
    }

    func invalidateCapabilitiesCache(for serverID: String? = nil) {
        if let serverID {
            capabilitiesCache.removeValue(forKey: serverID)
        } else {
            capabilitiesCache.removeAll()
        }
    }

    func getDiagnostics(server: ServerConfig? = nil) async throws -> DaemonDiagnosticsResponse {
        let data = try await request(path: "/diagnostics", method: "GET", server: server)
        return try JSONDecoder().decode(DaemonDiagnosticsResponse.self, from: data)
    }

    func createSession(name: String, cwd: String) async throws {
        if isDemoMode { return }
        let body = CreateSessionRequest(name: name, cwd: cwd)
        _ = try await request(path: "/sessions", method: "POST", body: body)
    }

    func sendInput(target: String, text: String) async throws {
        if isDemoMode {
            var history = demoInputHistory[target] ?? []
            history.append(text)
            demoInputHistory[target] = history
            return
        }
        let body = SendInputRequest(text: text)
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)/input", method: "POST", body: body)
    }

    func sendEscape(target: String) async throws {
        if isDemoMode { return }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)/escape", method: "POST")
    }

    func sendKey(target: String, key: String) async throws {
        if isDemoMode { return }
        let body = SendKeyRequest(key: key)
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(
            path: "/panes/\(encodedTarget)/key",
            method: "POST",
            body: body,
            timeoutSeconds: 2
        )
    }

    func sendShortcutKeys(target: String, keys: [String], preferBatch: Bool) async throws {
        if isDemoMode || keys.isEmpty { return }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target

        if preferBatch, keys.count > 1 {
            let batchBody = SendKeysRequest(keys: keys)
            do {
                _ = try await request(
                    path: "/panes/\(encodedTarget)/keys",
                    method: "POST",
                    body: batchBody,
                    timeoutSeconds: 2
                )
                return
            } catch let error as APIError {
                if case .httpError(let statusCode, let path, _, _) = error,
                   statusCode == 404,
                   path.contains("/panes/"),
                   path.hasSuffix("/keys") {
                    // Fallback for hosts that have not deployed schema v4 batch endpoint yet.
                } else {
                    throw error
                }
            }
        }

        // Preserve ordering when falling back to single-key route.
        for key in keys {
            let body = SendKeyRequest(key: key)
            _ = try await request(
                path: "/panes/\(encodedTarget)/key",
                method: "POST",
                body: body,
                timeoutSeconds: 2
            )
        }
    }

    func probeShortcutKeyEndpoint(target: String, server: ServerConfig? = nil) async throws {
        if isDemoMode { return }
        let body = SendKeyRequest(key: "Enter")
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)/key?probe=true", method: "POST", body: body, server: server)
    }

    func getOutput(target: String, lines: Int = 200) async throws -> String {
        if isDemoMode {
            let baseOutput = Self.demoOutput(for: target)
            let history = demoInputHistory[target] ?? []
            if history.isEmpty {
                return baseOutput
            }
            return baseOutput + Self.demoResponse(for: history)
        }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        let data = try await request(path: "/panes/\(encodedTarget)/output?lines=\(lines)", method: "GET")
        let response = try JSONDecoder().decode(OutputResponse.self, from: data)
        return response.output
    }

    func deletePane(target: String) async throws {
        if isDemoMode { return }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)", method: "DELETE")
    }

    func startPairing(deviceId: String, deviceName: String, serverName: String) async throws -> PairingStartResponse {
        guard !pushServerBaseURL.isEmpty else {
            throw APIError.serverError("Push server base URL is not configured")
        }
        let startBody = PairingStartRequest(
            deviceId: deviceId,
            deviceName: deviceName,
            serverName: serverName
        )
        let startData = try await requestToPushServer(
            path: "/v1/pairings/start",
            method: "POST",
            body: startBody,
            bearerToken: nil
        )
        return try JSONDecoder().decode(PairingStartResponse.self, from: startData)
    }

    func registerAPNsDevice(
        token: String,
        deviceId: String,
        serverName: String,
        deviceRegisterToken: String
    ) async throws -> RegisterDeviceResponse {
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        let registerBody = RegisterDeviceRequest(
            token: token,
            sandbox: sandbox,
            deviceId: deviceId,
            serverName: serverName
        )
        let responseData = try await requestToPushServer(
            path: "/v1/devices/register",
            method: "POST",
            body: registerBody,
            bearerToken: deviceRegisterToken
        )
        return try JSONDecoder().decode(RegisterDeviceResponse.self, from: responseData)
    }

    func registerAPNsDeviceForActiveServer(token: String) async throws -> RegisterDeviceResponse {
        guard let server = ServerConfigManager.shared.activeServer else {
            throw APIError.serverError("No active server")
        }
        let pairing = try await startPairing(
            deviceId: server.deviceId,
            deviceName: UIDevice.current.name,
            serverName: server.serverName
        )
        return try await registerAPNsDevice(
            token: token,
            deviceId: server.deviceId,
            serverName: server.serverName,
            deviceRegisterToken: pairing.deviceRegisterToken
        )
    }

    func reportIOSMetrics(deviceId: String, deltas: IOSMetricsIngestRequest) async throws {
        guard !deltas.isEmpty else { return }
        guard !pushServerBaseURL.isEmpty else {
            throw APIError.serverError("Push server base URL is not configured")
        }

        guard let server = ServerConfigManager.shared.servers.first(where: { $0.deviceId == deviceId }) else {
            throw APIError.serverError("Server not found for device \(deviceId)")
        }

        guard let deviceApiToken = server.deviceApiToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceApiToken.isEmpty else {
            throw APIError.serverError("Push device API token is missing. Re-run onboarding for this server.")
        }

        _ = try await requestToPushServer(
            path: "/v1/metrics/ios",
            method: "POST",
            body: deltas,
            bearerToken: deviceApiToken
        )
    }

    func listMutes(deviceApiToken: String? = nil) async throws -> [MuteRule] {
        let bearer = try resolveDeviceAPIToken(override: deviceApiToken)
        let emptyBody: String? = nil
        let data = try await requestToPushServer(
            path: "/v1/mutes",
            method: "GET",
            body: emptyBody,
            bearerToken: bearer
        )
        return try JSONDecoder().decode([MuteRule].self, from: data)
    }

    func createMute(_ requestBody: CreateMuteRequestBody, deviceApiToken: String? = nil) async throws -> CreateMuteResponse {
        let bearer = try resolveDeviceAPIToken(override: deviceApiToken)
        let data = try await requestToPushServer(
            path: "/v1/mutes",
            method: "POST",
            body: requestBody,
            bearerToken: bearer
        )
        return try JSONDecoder().decode(CreateMuteResponse.self, from: data)
    }

    func deleteMute(id: String, deviceApiToken: String? = nil) async throws {
        let bearer = try resolveDeviceAPIToken(override: deviceApiToken)
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let emptyBody: String? = nil
        _ = try await requestToPushServer(
            path: "/v1/mutes/\(encodedId)",
            method: "DELETE",
            body: emptyBody,
            bearerToken: bearer
        )
    }

    private func resolveDeviceAPIToken(override: String?) throws -> String {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let deviceApiToken {
            let trimmed = deviceApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        throw APIError.serverError("Push device API token is missing. Re-run onboarding for this server.")
    }

    private func requestToPushServer<T: Encodable>(
        path: String,
        method: String,
        body: T? = nil,
        bearerToken: String?,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> Data {
        guard let url = URL(string: pushServerBaseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeoutSeconds {
            request.timeoutInterval = timeoutSeconds
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.networkError(NSError(domain: "Invalid response", code: 0))
            }

            switch httpResponse.statusCode {
            case 200...299:
                return data
            default:
                let decodedError = decodeErrorResponse(from: data)
                throw APIError.httpError(
                    statusCode: httpResponse.statusCode,
                    path: path,
                    code: decodedError?.code,
                    message: decodedError?.error
                )
            }
        } catch let error as URLError {
            let message = friendlyNetworkErrorMessage(for: error, url: url)
            let wrapped = NSError(
                domain: "TmuxChatAPI.Network",
                code: error.errorCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            throw APIError.networkError(wrapped)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func request<T: Encodable>(
        path: String,
        method: String,
        body: T? = nil,
        server: ServerConfig? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> Data {
        let targetServer = server ?? ServerConfigManager.shared.activeServer
        guard let url = makeControlPlaneURL(path: path, server: targetServer) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeoutSeconds {
            request.timeoutInterval = timeoutSeconds
        }

        if let token = targetServer?.controlToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.networkError(NSError(domain: "Invalid response", code: 0))
            }

            switch httpResponse.statusCode {
            case 200...299:
                isAuthenticated = true
                authErrorType = nil
                return data
            case 401, 403:
                isAuthenticated = false
                authErrorType = .deviceTokenInvalid
                if let serverID = targetServer?.deviceId {
                    invalidateCapabilitiesCache(for: serverID)
                }
                throw APIError.unauthorized(.deviceTokenInvalid)
            default:
                if path == "/capabilities", let serverID = targetServer?.deviceId {
                    invalidateCapabilitiesCache(for: serverID)
                }
                let decodedError = decodeErrorResponse(from: data)
                throw APIError.httpError(
                    statusCode: httpResponse.statusCode,
                    path: path,
                    code: decodedError?.code,
                    message: decodedError?.error
                )
            }
        } catch let error as URLError {
            let message = friendlyNetworkErrorMessage(for: error, url: url)
            let wrapped = NSError(
                domain: "TmuxChatAPI.Network",
                code: error.errorCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            throw APIError.networkError(wrapped)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func makeControlPlaneURL(path: String, server: ServerConfig?) -> URL? {
        let baseURL = server?.serverURL ?? ""
        guard let normalizedBaseURL = normalizeControlPlaneBaseURL(baseURL) else {
            return nil
        }
        return URL(string: normalizedBaseURL + path)
    }

    private func capabilitiesCacheKey(for server: ServerConfig?) -> String? {
        if let server {
            return server.deviceId
        }
        return ServerConfigManager.shared.activeServer?.deviceId
    }

    private func decodeErrorResponse(from data: Data) -> ErrorResponse? {
        try? JSONDecoder().decode(ErrorResponse.self, from: data)
    }

    private func normalizeControlPlaneBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host != nil else {
            return nil
        }

        let path = components.percentEncodedPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if path == "/healthz" || path == "/healthz/" || path == "/" {
            components.percentEncodedPath = ""
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil

        guard let normalized = components.string else {
            return nil
        }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    private func friendlyNetworkErrorMessage(for error: URLError, url: URL) -> String {
        let host = url.host ?? url.absoluteString
        let portSuffix = url.port.map { ":\($0)" } ?? ""
        let endpoint = "\(host)\(portSuffix)"
        let tailscaleHint = host.hasSuffix(".ts.net")
            ? " If using Tailscale, ensure this iPhone is connected to the same tailnet."
            : ""

        switch error.code {
        case .notConnectedToInternet:
            return "Cannot reach \(endpoint). Check internet connectivity.\(tailscaleHint)"
        case .cannotFindHost, .dnsLookupFailed:
            return "Cannot resolve host \(endpoint). Verify the server URL and DNS/Tailscale status."
        case .cannotConnectToHost, .timedOut, .networkConnectionLost:
            return "Cannot connect to \(endpoint). Verify server is running and reachable from this device.\(tailscaleHint)"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "TLS handshake failed for \(endpoint). Check HTTPS certificate and device time."
        default:
            return error.localizedDescription
        }
    }

    private func request(path: String, method: String) async throws -> Data {
        let empty: String? = nil
        return try await request(path: path, method: method, body: empty, timeoutSeconds: nil)
    }

    private func request(path: String, method: String, server: ServerConfig) async throws -> Data {
        let empty: String? = nil
        return try await request(path: path, method: method, body: empty, server: server, timeoutSeconds: nil)
    }

    private func request(path: String, method: String, server: ServerConfig?) async throws -> Data {
        let empty: String? = nil
        return try await request(path: path, method: method, body: empty, server: server, timeoutSeconds: nil)
    }
}

// MARK: - Demo Mode Data
extension TmuxChatAPI {
    static let demoCapabilities = DaemonCapabilitiesResponse(
        daemon: "tmux-chatd",
        version: "demo",
        capabilitiesSchemaVersion: 4,
        features: DaemonFeatureCapabilities(shortcutKeys: true, shortcutKeyBatch: true),
        endpoints: DaemonEndpointCapabilities(
            healthz: true,
            capabilities: true,
            diagnostics: true,
            sessions: true,
            panes: true,
            paneKey: true,
            paneKeys: true,
            paneKeyProbe: true,
            notify: true
        )
    )

    static let demoSessions: [Session] = [
        Session(
            name: "myproject",
            attached: true,
            windows: [
                Window(
                    index: 0,
                    name: "main",
                    active: true,
                    panes: [
                        Pane(index: 0, active: true, target: "myproject:0.0", currentPath: "/Users/demo/projects/myproject")
                    ]
                )
            ]
        ),
        Session(
            name: "claude-demo",
            attached: false,
            windows: [
                Window(
                    index: 0,
                    name: "claude",
                    active: true,
                    panes: [
                        Pane(index: 0, active: true, target: "claude-demo:0.0", currentPath: "/Users/demo/projects/webapp")
                    ]
                )
            ]
        )
    ]

    static func demoOutput(for target: String) -> String {
        if target.contains("claude") {
            return """
╭────────────────────────────────────────────────────────────────────╮
│ ● Claude Code                                                      │
╰────────────────────────────────────────────────────────────────────╯

> Help me refactor the authentication module

I'll help you refactor the authentication module. Let me first examine the
current implementation.

⏺ Read src/auth/mod.rs
⏺ Read src/auth/jwt.rs
⏺ Read src/auth/session.rs

I've analyzed the authentication module. Here's my refactoring plan:

1. Extract common validation logic into a shared trait
2. Implement proper error handling with custom error types
3. Add refresh token support

Would you like me to proceed with these changes?

"""
        } else {
            return """
$ ls -la
total 24
drwxr-xr-x   8 demo  staff   256 Dec 30 10:00 .
drwxr-xr-x  12 demo  staff   384 Dec 30 09:00 ..
-rw-r--r--   1 demo  staff   220 Dec 30 10:00 Cargo.toml
drwxr-xr-x   4 demo  staff   128 Dec 30 10:00 src
-rw-r--r--   1 demo  staff  1024 Dec 30 10:00 README.md

$ _
"""
        }
    }

    static func demoResponse(for inputs: [String]) -> String {
        var response = "\n"
        for input in inputs {
            response += "> \(input)\n\n"
            response += demoReply(for: input)
            response += "\n"
        }
        return response
    }

    private static func demoReply(for input: String) -> String {
        let lowercased = input.lowercased()

        if lowercased.contains("hello") || lowercased.contains("hi") {
            return "Hello! How can I help you today?\n"
        }
        if lowercased.contains("help") {
            return """
Available commands:
  - help: Show this message
  - status: Check system status
  - list: List files in current directory

"""
        }
        if lowercased.contains("status") {
            return """
System Status: OK
  CPU: 12%
  Memory: 4.2GB / 16GB
  Uptime: 3 days, 14 hours

"""
        }
        if lowercased.contains("list") || lowercased.contains("ls") {
            return """
Cargo.toml  README.md  src/  tests/

"""
        }
        if lowercased.contains("yes") || lowercased.contains("y") {
            return "Great! Proceeding with the changes...\n"
        }
        if lowercased.contains("no") || lowercased.contains("n") {
            return "Okay, let me know if you need anything else.\n"
        }

        return "I received your input: \"\(input)\"\n"
    }
}
