//
//  ReattachAPI.swift
//  Reattach
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
class ReattachAPI {
    static let shared = ReattachAPI()

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
        return trimmed
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
        bearerToken: String?
    ) async throws -> Data {
        guard let url = URL(string: pushServerBaseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            case 401, 403:
                throw APIError.unauthorized(.deviceTokenInvalid)
            default:
                if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                    throw APIError.serverError(errorResponse.error)
                }
                throw APIError.serverError("HTTP \(httpResponse.statusCode)")
            }
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
        server: ServerConfig? = nil
    ) async throws -> Data {
        let targetServer = server ?? ServerConfigManager.shared.activeServer
        let baseURL = targetServer?.serverURL ?? ""

        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
                throw APIError.unauthorized(.deviceTokenInvalid)
            default:
                if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                    throw APIError.serverError(errorResponse.error)
                }
                throw APIError.serverError("HTTP \(httpResponse.statusCode)")
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func request(path: String, method: String) async throws -> Data {
        let empty: String? = nil
        return try await request(path: path, method: method, body: empty)
    }

    private func request(path: String, method: String, server: ServerConfig) async throws -> Data {
        let empty: String? = nil
        return try await request(path: path, method: method, body: empty, server: server)
    }
}

// MARK: - Demo Mode Data
extension ReattachAPI {
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
