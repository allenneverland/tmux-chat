//
//  SSHCredentials.swift
//  Reattach
//

import Foundation

enum SSHAuthenticationMode: String, CaseIterable, Codable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }
}

enum SSHAuthenticationSecret: Equatable {
    case password(String)
    case privateKey(key: String, passphrase: String?)
}

struct SSHConnectionSpec: Equatable {
    let host: String
    let port: UInt16
    let username: String
    let secret: SSHAuthenticationSecret
}

private struct SSHStoredCredential: Codable {
    let host: String
    let port: UInt16
    let username: String
    let mode: SSHAuthenticationMode
    let password: String?
    let privateKey: String?
    let privateKeyPassphrase: String?
}

enum SSHCredentialStoreError: LocalizedError {
    case corrupted

    var errorDescription: String? {
        switch self {
        case .corrupted:
            return "Stored SSH credential is corrupted"
        }
    }
}

final class SSHCredentialStore {
    static let shared = SSHCredentialStore()

    private init() {}

    func save(_ spec: SSHConnectionSpec) throws -> String {
        let id = UUID().uuidString
        let payload = try encode(spec)
        try KeychainStore.shared.set(payload, for: id)
        return id
    }

    func load(id: String) throws -> SSHConnectionSpec {
        guard let data = try KeychainStore.shared.data(for: id) else {
            throw SSHCredentialStoreError.corrupted
        }
        let decoded = try JSONDecoder().decode(SSHStoredCredential.self, from: data)
        return try decode(decoded)
    }

    func replace(id: String, with spec: SSHConnectionSpec) throws {
        let payload = try encode(spec)
        try KeychainStore.shared.set(payload, for: id)
    }

    func delete(id: String?) {
        guard let id else { return }
        try? KeychainStore.shared.remove(account: id)
    }

    private func encode(_ spec: SSHConnectionSpec) throws -> Data {
        let stored: SSHStoredCredential
        switch spec.secret {
        case .password(let password):
            stored = SSHStoredCredential(
                host: spec.host,
                port: spec.port,
                username: spec.username,
                mode: .password,
                password: password,
                privateKey: nil,
                privateKeyPassphrase: nil
            )
        case .privateKey(let key, let passphrase):
            stored = SSHStoredCredential(
                host: spec.host,
                port: spec.port,
                username: spec.username,
                mode: .privateKey,
                password: nil,
                privateKey: key,
                privateKeyPassphrase: passphrase
            )
        }
        return try JSONEncoder().encode(stored)
    }

    private func decode(_ stored: SSHStoredCredential) throws -> SSHConnectionSpec {
        let secret: SSHAuthenticationSecret
        switch stored.mode {
        case .password:
            guard let password = stored.password else {
                throw SSHCredentialStoreError.corrupted
            }
            secret = .password(password)
        case .privateKey:
            guard let key = stored.privateKey else {
                throw SSHCredentialStoreError.corrupted
            }
            secret = .privateKey(key: key, passphrase: stored.privateKeyPassphrase)
        }
        return SSHConnectionSpec(
            host: stored.host,
            port: stored.port,
            username: stored.username,
            secret: secret
        )
    }
}
