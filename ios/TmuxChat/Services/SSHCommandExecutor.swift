//
//  SSHCommandExecutor.swift
//  TmuxChat
//

import Foundation

struct SSHCommandResult: Equatable {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int
}

enum SSHCommandExecutorError: LocalizedError {
    case sshLibraryUnavailable
    case connectionFailed(String)
    case commandFailed(exitCode: Int, stderr: String)
    case unsupportedPrivateKeyFormat
    case encryptedPrivateKeyUnsupported

    var errorDescription: String? {
        switch self {
        case .sshLibraryUnavailable:
            return "SSH client library is unavailable in this build."
        case .connectionFailed(let reason):
            return "SSH connection failed: \(reason)"
        case .commandFailed(let exitCode, let stderr):
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Remote command failed with exit code \(exitCode)"
            }
            return "Remote command failed (\(exitCode)): \(stderr)"
        case .unsupportedPrivateKeyFormat:
            return "Unsupported private key format. Use PEM-encoded ECDSA key."
        case .encryptedPrivateKeyUnsupported:
            return "Encrypted private keys are not supported in this build."
        }
    }
}

protocol SSHCommandExecuting {
    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult
}

#if canImport(SSHClient) && canImport(NIOSSH)
import CryptoKit
import NIOCore
import NIOSSH
import SSHClient

final class SSHCommandExecutor: SSHCommandExecuting {
    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult {
        let auth = try authentication(for: connection)
        let ssh = SSHConnection(
            host: connection.host,
            port: connection.port,
            authentication: auth
        )

        do {
            try await ssh.start()
            let response = try await ssh.execute(SSHCommand(command))
            await ssh.cancel()
            let stdout = String(data: response.standardOutput ?? Data(), encoding: .utf8) ?? ""
            let stderr = String(data: response.errorOutput ?? Data(), encoding: .utf8) ?? ""
            let result = SSHCommandResult(
                command: command,
                stdout: stdout,
                stderr: stderr,
                exitCode: response.status.exitStatus
            )
            guard result.exitCode == 0 else {
                throw SSHCommandExecutorError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            return result
        } catch let error as SSHCommandExecutorError {
            await ssh.cancel()
            throw error
        } catch {
            await ssh.cancel()
            throw SSHCommandExecutorError.connectionFailed(error.localizedDescription)
        }
    }

    private func authentication(for connection: SSHConnectionSpec) throws -> SSHAuthentication {
        switch connection.secret {
        case .password(let password):
            return SSHAuthentication(
                username: connection.username,
                method: .password(.init(password)),
                hostKeyValidation: .acceptAll()
            )
        case .privateKey(let key, let passphrase):
            if let passphrase, !passphrase.isEmpty {
                throw SSHCommandExecutorError.encryptedPrivateKeyUnsupported
            }
            let parsed = try parsePEMPrivateKey(key)
            let delegate = StaticPrivateKeyAuthDelegate(username: connection.username, privateKey: parsed)
            return SSHAuthentication(
                username: connection.username,
                method: .custom(delegate),
                hostKeyValidation: .acceptAll()
            )
        }
    }

    private func parsePEMPrivateKey(_ key: String) throws -> NIOSSHPrivateKey {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
        }

        if let p256 = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p256Key: p256)
        }
        if let p384 = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p384Key: p384)
        }
        if let p521 = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p521Key: p521)
        }

        throw SSHCommandExecutorError.unsupportedPrivateKeyFormat
    }
}

private final class StaticPrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var used = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !used else {
            nextChallengePromise.succeed(nil)
            return
        }
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHCommandExecutorError.connectionFailed("Server does not accept public-key auth"))
            return
        }

        used = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        )
        nextChallengePromise.succeed(offer)
    }
}
#else
final class SSHCommandExecutor: SSHCommandExecuting {
    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult {
        _ = command
        _ = connection
        throw SSHCommandExecutorError.sshLibraryUnavailable
    }
}
#endif
