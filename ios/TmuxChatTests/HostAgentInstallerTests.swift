import Foundation
import Testing
@testable import TmuxChat

private final class RecordingSSHExecutor: SSHCommandExecuting {
    private(set) var commands: [String] = []
    private let statusJSON: String

    init(
        statusJSON: String = #"{"daemon":"host-agent","version":"0.1.0","status_schema_version":3,"paired":true,"socket_connectable":true,"tmux_hook_active":true,"tmux_monitor_bell":"on","tmux_bell_action":"any","service_active":true}"#
    ) {
        self.statusJSON = statusJSON
    }

    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult {
        _ = connection
        commands.append(command)
        if command.contains("status --json") {
            return SSHCommandResult(command: command, stdout: statusJSON, stderr: "", exitCode: 0)
        }
        return SSHCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
    }
}

private final class FailingSSHExecutor: SSHCommandExecuting {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult {
        _ = command
        _ = connection
        throw error
    }
}

private final class TmuxChatdInstallFailingSSHExecutor: SSHCommandExecuting {
    private(set) var commands: [String] = []

    func run(command: String, on connection: SSHConnectionSpec) async throws -> SSHCommandResult {
        _ = connection
        commands.append(command)
        if command.contains("tmux-chatd.tgz") {
            throw SSHCommandExecutorError.commandFailed(
                exitCode: 1,
                stderr: "curl: (22) The requested URL returned error: 404"
            )
        }
        return SSHCommandResult(command: command, stdout: "/usr/local/bin/tmux-chatd\n", stderr: "", exitCode: 0)
    }
}

struct HostAgentInstallerTests {
    private let runtimeConfig = HostAgentRuntimeConfig(
        hostAgentReleaseTag: "latest",
        requiredStatusSchemaVersion: 3
    )

    @Test
    func verifyHostAgentReadinessSucceedsWithoutBashFields() async throws {
        let ssh = RecordingSSHExecutor(
            statusJSON: #"{"daemon":"host-agent","version":"0.1.0","status_schema_version":3,"paired":true,"socket_connectable":true,"tmux_hook_active":true,"tmux_monitor_bell":"on","tmux_bell_action":"any","service_active":true}"#
        )
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        try await installer.verifyHostAgentReadiness(on: connection)
    }

    @Test
    func verifyHostAgentReadinessFailsWhenStatusSchemaTooOld() async throws {
        let ssh = RecordingSSHExecutor(
            statusJSON: #"{"daemon":"host-agent","version":"0.1.0","status_schema_version":2,"paired":true,"socket_connectable":true,"tmux_hook_active":true,"tmux_monitor_bell":"on","tmux_bell_action":"any","service_active":true}"#
        )
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        var message = ""
        do {
            try await installer.verifyHostAgentReadiness(on: connection)
        } catch {
            message = error.localizedDescription
        }
        #expect(!message.isEmpty)
        #expect(message.contains("status schema is incompatible"))
    }

    @Test
    func installUsesLatestHostAgentReleaseSelector() async throws {
        let ssh = RecordingSSHExecutor()
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        try await installer.install(
            on: connection,
            pushServerBaseURL: "https://push.example.com",
            releaseAssetName: "host-agent-linux-x86_64-musl.tar.gz"
        )

        let command = try #require(ssh.commands.first)
        #expect(command.contains("/releases/latest/download/host-agent-linux-x86_64-musl.tar.gz"))
    }

    @Test
    func installSupportsPinnedHostAgentReleaseSelector() async throws {
        let ssh = RecordingSSHExecutor()
        let pinnedConfig = HostAgentRuntimeConfig(
            hostAgentReleaseTag: "v1.0.20",
            requiredStatusSchemaVersion: 3
        )
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: pinnedConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        try await installer.install(
            on: connection,
            pushServerBaseURL: "https://push.example.com",
            releaseAssetName: "host-agent-linux-x86_64-musl.tar.gz"
        )

        let command = try #require(ssh.commands.first)
        #expect(command.contains("/releases/download/v1.0.20/host-agent-linux-x86_64-musl.tar.gz"))
    }

    @Test
    func installFailsWhenReleaseTagIsMissing() async throws {
        let ssh = RecordingSSHExecutor()
        let badConfig = HostAgentRuntimeConfig(hostAgentReleaseTag: "", requiredStatusSchemaVersion: 3)
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: badConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        var message = ""
        do {
            try await installer.install(
                on: connection,
                pushServerBaseURL: "https://push.example.com",
                releaseAssetName: "host-agent-linux-x86_64-musl.tar.gz"
            )
        } catch {
            message = error.localizedDescription
        }
        #expect(!message.isEmpty)
        #expect(message.contains("release selector is not configured"))
        #expect(ssh.commands.isEmpty)
    }

    @Test
    func installFailsWhenReleaseSelectorIsInvalid() async throws {
        let ssh = RecordingSSHExecutor()
        let badConfig = HostAgentRuntimeConfig(hostAgentReleaseTag: "stable", requiredStatusSchemaVersion: 3)
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: badConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        var message = ""
        do {
            try await installer.install(
                on: connection,
                pushServerBaseURL: "https://push.example.com",
                releaseAssetName: "host-agent-linux-x86_64-musl.tar.gz"
            )
        } catch {
            message = error.localizedDescription
        }
        #expect(!message.isEmpty)
        #expect(message.contains("must be 'latest' or start with 'v'"))
        #expect(ssh.commands.isEmpty)
    }

    @Test
    func installReportsReleaseAssetNotFoundWhenDownloadReturns404() async throws {
        let stderr = """
        curl: (22) The requested URL returned error: 404
        failed to download host-agent archive from 'https://github.com/allenneverland/tmux-chat/releases/latest/download/host-agent-linux-x86_64-musl.tar.gz'
        """
        let ssh = FailingSSHExecutor(
            error: SSHCommandExecutorError.commandFailed(exitCode: 1, stderr: stderr)
        )
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        var message = ""
        do {
            try await installer.install(
                on: connection,
                pushServerBaseURL: "https://push.example.com",
                releaseAssetName: "host-agent-linux-x86_64-musl.tar.gz"
            )
        } catch {
            message = error.localizedDescription
        }

        #expect(!message.isEmpty)
        #expect(message.contains("release asset not found"))
        #expect(message.contains("release_selector=latest"))
        #expect(message.contains("host-agent-linux-x86_64-musl.tar.gz"))
    }

    @Test
    func ensureTmuxChatdInstalledFailsWhenLatestInstallFails() async throws {
        let ssh = TmuxChatdInstallFailingSSHExecutor()
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        var message = ""
        do {
            _ = try await installer.ensureTmuxChatdInstalled(on: connection)
        } catch {
            message = error.localizedDescription
        }

        #expect(!message.isEmpty)
        #expect(message.contains("release asset not found"))
        #expect(ssh.commands.count == 1)
        #expect(ssh.commands.first?.contains("tmux-chatd.tgz") == true)
    }
}
