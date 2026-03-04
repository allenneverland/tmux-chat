//
//  SSHPrivateKeyParser.swift
//  TmuxChat
//

import Foundation

#if canImport(SSHClient) && canImport(NIOSSH)
import CryptoKit
import NIOSSH

enum SSHPrivateKeyParser {
    static func parse(privateKey: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let trimmed = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        if let passphrase, !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SSHCommandExecutorError.encryptedPrivateKeyUnsupported
        }

        if let ecdsa = try parsePEMECDSAKey(trimmed) {
            return ecdsa
        }

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHEd25519Key(trimmed)
        }

        throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
    }

    private static func parsePEMECDSAKey(_ privateKey: String) throws -> NIOSSHPrivateKey? {
        if let p256 = try? P256.Signing.PrivateKey(pemRepresentation: privateKey) {
            return NIOSSHPrivateKey(p256Key: p256)
        }
        if let p384 = try? P384.Signing.PrivateKey(pemRepresentation: privateKey) {
            return NIOSSHPrivateKey(p384Key: p384)
        }
        if let p521 = try? P521.Signing.PrivateKey(pemRepresentation: privateKey) {
            return NIOSSHPrivateKey(p521Key: p521)
        }
        return nil
    }

    private static func parseOpenSSHEd25519Key(_ pem: String) throws -> NIOSSHPrivateKey {
        let blob = try decodeOpenSSHPem(pem)
        let magic = Data("openssh-key-v1\u{0}".utf8)
        guard blob.starts(with: magic) else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        var reader = SSHBinaryReader(data: blob)
        _ = try reader.readData(count: magic.count)

        let cipherName = try reader.readUTF8String()
        let kdfName = try reader.readUTF8String()
        _ = try reader.readStringData()

        guard cipherName == "none", kdfName == "none" else {
            throw SSHCommandExecutorError.encryptedPrivateKeyUnsupported
        }

        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        _ = try reader.readStringData()
        let privateBlock = try reader.readStringData()

        var privateReader = SSHBinaryReader(data: privateBlock)
        let check1 = try privateReader.readUInt32()
        let check2 = try privateReader.readUInt32()
        guard check1 == check2 else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        let keyType = try privateReader.readUTF8String()
        guard keyType == "ssh-ed25519" else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        let publicKey = try privateReader.readStringData()
        let privateKeyAndPublic = try privateReader.readStringData()
        _ = try privateReader.readStringData()

        guard publicKey.count == 32, privateKeyAndPublic.count == 64 else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        let publicSuffix = privateKeyAndPublic.suffix(32)
        guard Data(publicSuffix) == publicKey else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        try validatePadding(privateReader.remainingData)

        let seed = Data(privateKeyAndPublic.prefix(32))
        guard let ed25519 = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        return NIOSSHPrivateKey(ed25519Key: ed25519)
    }

    private static func decodeOpenSSHPem(_ pem: String) throws -> Data {
        let lines = pem
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard
            let first = lines.first,
            let last = lines.last,
            first == "-----BEGIN OPENSSH PRIVATE KEY-----",
            last == "-----END OPENSSH PRIVATE KEY-----"
        else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        let payload = lines.dropFirst().dropLast().joined()
        guard let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }
        return decoded
    }

    private static func validatePadding(_ data: Data) throws {
        for (index, byte) in data.enumerated() {
            let expected = UInt8(index + 1)
            guard byte == expected else {
                throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
            }
        }
    }
}

private struct SSHBinaryReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var remainingData: Data {
        data.suffix(from: offset)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readStringData() throws -> Data {
        let length = try readUInt32()
        guard let count = Int(exactly: length) else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }
        return try readData(count: count)
    }

    mutating func readUTF8String() throws -> String {
        let bytes = try readStringData()
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }
        let slice = data[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }
}
#endif
