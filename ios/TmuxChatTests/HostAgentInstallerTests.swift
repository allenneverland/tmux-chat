import Foundation
import Testing
@testable import TmuxChat

private final class RecordingSSHExecutor: SSHCommandExecuting {
    private(set) var commands: [String] = []

    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult {
        _ = connection
        commands.append(command)
        return SSHCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
    }
}

struct HostAgentInstallerTests {
    @Test
    func installBashAutoNotifyUsesExpectedRemoteCommand() async throws {
        let ssh = RecordingSSHExecutor()
        let installer = HostAgentInstaller(sshExecutor: ssh)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        try await installer.installBashAutoNotify(on: connection, minSeconds: 3)

        #expect(ssh.commands.count == 1)
        let command = try #require(ssh.commands.first)
        #expect(command.contains("/bin/sh -lc"))
        #expect(command.contains("install-shell-notify --min-seconds 3"))
    }

    @Test
    func installBashAutoNotifyClampsMinSecondsToOne() async throws {
        let ssh = RecordingSSHExecutor()
        let installer = HostAgentInstaller(sshExecutor: ssh)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        try await installer.installBashAutoNotify(on: connection, minSeconds: 0)

        let command = try #require(ssh.commands.first)
        #expect(command.contains("install-shell-notify --min-seconds 1"))
    }
}
