//
//  Session.swift
//  Reattach
//

import Foundation

struct Pane: Codable, Identifiable, Hashable {
    let index: UInt32
    let active: Bool
    let target: String
    let currentPath: String

    var id: String { target }

    var shortPath: String {
        (currentPath as NSString).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case index, active, target
        case currentPath = "current_path"
    }
}

struct Window: Codable, Identifiable, Hashable {
    let index: UInt32
    let name: String
    let active: Bool
    let panes: [Pane]

    var id: UInt32 { index }
}

struct Session: Codable, Identifiable, Hashable {
    let name: String
    let attached: Bool
    let windows: [Window]

    var id: String { name }
}

struct CreateSessionRequest: Codable {
    let name: String
    let cwd: String
}

struct SendInputRequest: Codable {
    let text: String
}

struct RegisterDeviceRequest: Codable {
    let token: String
    let sandbox: Bool
    let deviceId: String
    let serverName: String

    enum CodingKeys: String, CodingKey {
        case token, sandbox
        case deviceId = "device_id"
        case serverName = "server_name"
    }
}

struct PairingStartRequest: Codable {
    let deviceId: String
    let deviceName: String
    let serverName: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case serverName = "server_name"
    }
}

struct PairingStartResponse: Codable {
    let pairingId: String
    let pairingToken: String
    let deviceRegisterToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case pairingId = "pairing_id"
        case pairingToken = "pairing_token"
        case deviceRegisterToken = "device_register_token"
        case expiresAt = "expires_at"
    }
}

struct RegisterDeviceResponse: Codable {
    let registrationId: String
    let deviceApiToken: String

    enum CodingKeys: String, CodingKey {
        case registrationId = "registration_id"
        case deviceApiToken = "device_api_token"
    }
}

struct IssuedDeviceCredentials: Decodable {
    let deviceId: String
    let deviceName: String
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case deviceToken = "device_token"
    }
}

struct OutputResponse: Codable {
    let output: String
}

struct ErrorResponse: Codable {
    let error: String
}

enum MuteScope: String, CaseIterable, Codable, Hashable, Identifiable {
    case host
    case session
    case pane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host:
            return "Host"
        case .session:
            return "Session"
        case .pane:
            return "Pane"
        }
    }
}

enum MuteSource: String, CaseIterable, Codable, Hashable, Identifiable {
    case all
    case bell
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .bell:
            return "Bell"
        case .agent:
            return "Agent"
        }
    }
}

struct MuteRule: Codable, Identifiable, Hashable {
    let id: String
    let scope: MuteScope
    let sessionName: String?
    let paneTarget: String?
    let source: MuteSource
    let until: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, scope, source, until
        case sessionName = "session_name"
        case paneTarget = "pane_target"
        case createdAt = "created_at"
    }
}

struct CreateMuteRequestBody: Codable {
    let scope: MuteScope
    let sessionName: String?
    let paneTarget: String?
    let source: MuteSource
    let until: String?

    enum CodingKeys: String, CodingKey {
        case scope, source, until
        case sessionName = "session_name"
        case paneTarget = "pane_target"
    }
}

struct CreateMuteResponse: Codable {
    let id: String
}
