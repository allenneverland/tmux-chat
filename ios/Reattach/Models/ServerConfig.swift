//
//  ServerConfig.swift
//  Reattach
//

import Foundation
import Observation

struct ServerConfig: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    var serverURL: String
    var controlToken: String
    var deviceId: String
    var deviceName: String
    var serverName: String
    var deviceApiToken: String?
    var sshCredentialId: String?
    var needsPushRebind: Bool
    var registeredAt: Date

    // Backward-compatible alias for legacy call sites and persisted payloads.
    var deviceToken: String {
        get { controlToken }
        set { controlToken = newValue }
    }

    init(
        serverURL: String,
        controlToken: String,
        deviceId: String,
        deviceName: String,
        serverName: String,
        deviceApiToken: String? = nil,
        sshCredentialId: String? = nil,
        needsPushRebind: Bool = false,
        registeredAt: Date
    ) {
        self.serverURL = serverURL
        self.controlToken = controlToken
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.serverName = serverName
        self.deviceApiToken = deviceApiToken
        self.sshCredentialId = sshCredentialId
        self.needsPushRebind = needsPushRebind
        self.registeredAt = registeredAt
    }

    private enum CodingKeys: String, CodingKey {
        case serverURL
        case controlToken
        case legacyDeviceToken = "deviceToken"
        case deviceId
        case deviceName
        case serverName
        case deviceApiToken
        case sshCredentialId
        case needsPushRebind
        case registeredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        controlToken = try container.decodeIfPresent(String.self, forKey: .controlToken)
            ?? container.decode(String.self, forKey: .legacyDeviceToken)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        serverName = try container.decode(String.self, forKey: .serverName)
        deviceApiToken = try container.decodeIfPresent(String.self, forKey: .deviceApiToken)
        sshCredentialId = try container.decodeIfPresent(String.self, forKey: .sshCredentialId)
        needsPushRebind = try container.decodeIfPresent(Bool.self, forKey: .needsPushRebind) ?? false
        registeredAt = try container.decode(Date.self, forKey: .registeredAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(controlToken, forKey: .controlToken)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(serverName, forKey: .serverName)
        try container.encodeIfPresent(deviceApiToken, forKey: .deviceApiToken)
        try container.encodeIfPresent(sshCredentialId, forKey: .sshCredentialId)
        try container.encode(needsPushRebind, forKey: .needsPushRebind)
        try container.encode(registeredAt, forKey: .registeredAt)
    }
}

@MainActor
@Observable
class ServerConfigManager {
    static let shared = ServerConfigManager()

    var servers: [ServerConfig] = []
    var activeServerId: String?
    var isDemoMode: Bool = false

    var activeServer: ServerConfig? {
        guard let id = activeServerId else { return servers.first }
        return servers.first { $0.id == id }
    }

    var isConfigured: Bool {
        isDemoMode || !servers.isEmpty
    }

    func enableDemoMode() {
        isDemoMode = true
        userDefaults.set(true, forKey: demoModeKey)
    }

    func disableDemoMode() {
        isDemoMode = false
        userDefaults.removeObject(forKey: demoModeKey)
    }

    private let userDefaults = UserDefaults.standard
    private let serversKey = "servers_config"
    private let activeServerKey = "active_server_id"
    private let demoModeKey = "demo_mode"

    private init() {
        loadConfig()
    }

    func loadConfig() {
        if let data = userDefaults.data(forKey: serversKey),
           let servers = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            self.servers = servers
        }
        self.activeServerId = userDefaults.string(forKey: activeServerKey)
        self.isDemoMode = userDefaults.bool(forKey: demoModeKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            userDefaults.set(data, forKey: serversKey)
        }
        userDefaults.set(activeServerId, forKey: activeServerKey)
    }

    var canAddServer: Bool {
        servers.count < PurchaseManager.shared.serverLimit
    }

    func addServer(_ config: ServerConfig) {
        // Remove existing config with same deviceId if exists
        let isUpdate = servers.contains { $0.deviceId == config.deviceId }
        servers.removeAll { $0.deviceId == config.deviceId }

        // Check limit only for new servers
        if !isUpdate && !canAddServer {
            return
        }

        servers.append(config)

        // Set as active if it's the first server
        if activeServerId == nil {
            activeServerId = config.deviceId
        }
        save()
    }

    func removeServer(_ serverId: String) {
        servers.removeAll { $0.id == serverId }
        if activeServerId == serverId {
            activeServerId = servers.first?.id
        }
        save()
    }

    func updateServer(_ server: ServerConfig) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
            save()
        }
    }

    func setActiveServer(_ serverId: String) {
        guard servers.contains(where: { $0.id == serverId }) else { return }
        activeServerId = serverId
        save()
    }

    func markNeedsPushRebind(_ needsRebind: Bool, for serverId: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[index].needsPushRebind = needsRebind
        save()
    }

    func markAllServersNeedsPushRebind() {
        guard !servers.isEmpty else { return }
        var changed = false
        for index in servers.indices {
            if !servers[index].needsPushRebind {
                servers[index].needsPushRebind = true
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    func clearAll() {
        servers = []
        activeServerId = nil
        userDefaults.removeObject(forKey: serversKey)
        userDefaults.removeObject(forKey: activeServerKey)
    }
}
