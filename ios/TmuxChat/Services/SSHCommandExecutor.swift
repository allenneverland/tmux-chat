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

enum SSHCommandTimeoutProfile: Equatable {
    case quick
    case standard
    case long

    var connectTimeout: TimeInterval {
        switch self {
        case .quick:
            return 10
        case .standard:
            return 15
        case .long:
            return 20
        }
    }

    var commandTimeout: TimeInterval {
        switch self {
        case .quick:
            return 15
        case .standard:
            return 45
        case .long:
            return 180
        }
    }
}

enum SSHCommandExecutorError: LocalizedError {
    case sshLibraryUnavailable
    case connectionFailed(String)
    case commandFailed(exitCode: Int, stderr: String)
    case commandTimedOut(command: String, timeout: TimeInterval)
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
        case .commandTimedOut(let command, let timeout):
            return
                "Remote command timed out after \(Int(timeout))s: \(command). Verify remote host performance and retry."
        case .unsupportedPrivateKeyFormat:
            return "Unsupported private key format. Supported formats: PEM-encoded ECDSA, or unencrypted OpenSSH Ed25519."
        case .encryptedPrivateKeyUnsupported:
            return "Encrypted private keys are not supported in this build. Use an unencrypted key or password authentication."
        }
    }
}

protocol SSHCommandExecuting {
    func run(
        command: String,
        on connection: SSHConnectionSpec,
        timeoutProfile: SSHCommandTimeoutProfile
    ) async throws -> SSHCommandResult
}

extension SSHCommandExecuting {
    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult {
        try await run(command: command, on: connection, timeoutProfile: .standard)
    }
}

#if canImport(SSHClient) && canImport(NIOSSH)
import NIOCore
import NIOSSH
import SSHClient

final class SSHCommandExecutor: SSHCommandExecuting {
    func run(
        command: String,
        on connection: SSHConnectionSpec,
        timeoutProfile: SSHCommandTimeoutProfile = .standard
    ) async throws -> SSHCommandResult {
        let auth = try authentication(for: connection)
        let ssh = SSHConnection(
            host: connection.host,
            port: connection.port,
            authentication: auth
        )

        do {
            do {
                try await ssh.start(withTimeout: timeoutProfile.connectTimeout)
            } catch let error as SSHConnectionError {
                throw SSHCommandExecutorError.connectionFailed(
                    connectionDiagnostic(
                        for: error,
                        host: connection.host,
                        port: connection.port,
                        timeout: timeoutProfile.connectTimeout
                    )
                )
            }

            let response: SSHCommandResponse
            do {
                response = try await ssh.execute(
                    SSHCommand(command),
                    withTimeout: timeoutProfile.commandTimeout
                )
            } catch let error as SSHConnectionError {
                throw commandError(
                    for: error,
                    command: command,
                    timeout: timeoutProfile.commandTimeout
                )
            }

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
        } catch let error as SSHConnectionError {
            await ssh.cancel()
            throw SSHCommandExecutorError.connectionFailed(
                connectionDiagnostic(
                    for: error,
                    host: connection.host,
                    port: connection.port,
                    timeout: timeoutProfile.connectTimeout
                )
            )
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
            let parsed = try SSHPrivateKeyParser.parse(privateKey: key, passphrase: passphrase)
            let delegate = StaticPrivateKeyAuthDelegate(username: connection.username, privateKey: parsed)
            return SSHAuthentication(
                username: connection.username,
                method: .custom(delegate),
                hostKeyValidation: .acceptAll()
            )
        }
    }

    private func commandError(
        for error: SSHConnectionError,
        command: String,
        timeout: TimeInterval
    ) -> SSHCommandExecutorError {
        let summary = summarize(command: command)
        switch error {
        case .timeout:
            return .commandTimedOut(command: summary, timeout: timeout)
        case .requireActiveConnection:
            return .connectionFailed(
                "SSH connection became inactive while running command: \(summary). Verify host stability and SSH session health."
            )
        case .unknown:
            return .connectionFailed(
                "SSH command execution failed unexpectedly: \(summary). Verify remote shell environment and retry."
            )
        }
    }

    private func connectionDiagnostic(
        for error: SSHConnectionError,
        host: String,
        port: UInt16,
        timeout: TimeInterval
    ) -> String {
        switch error {
        case .timeout:
            return
                "Timed out while connecting to \(host):\(port) within \(Int(timeout))s. Verify the host is reachable and SSH port is correct (usually 22)."
        case .requireActiveConnection:
            return "SSH connection is not active. Verify host, port, username, and authentication settings."
        case .unknown:
            return "SSH handshake or authentication failed for \(host):\(port). Verify SSH host/port (usually 22), username, and key/password. If using Tailscale, ensure this device is connected to the same tailnet."
        }
    }

    private func summarize(command: String) -> String {
        let collapsed = command
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 120 else {
            return collapsed
        }
        let prefix = collapsed.prefix(117)
        return "\(prefix)..."
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
    func run(
        command: String,
        on connection: SSHConnectionSpec,
        timeoutProfile: SSHCommandTimeoutProfile = .standard
    ) async throws -> SSHCommandResult {
        _ = command
        _ = connection
        _ = timeoutProfile
        throw SSHCommandExecutorError.sshLibraryUnavailable
    }
}
#endif
