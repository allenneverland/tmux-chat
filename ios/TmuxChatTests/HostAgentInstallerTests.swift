import Foundation
import Testing
@testable import TmuxChat

private final class RecordingSSHExecutor: SSHCommandExecuting {
    private(set) var commands: [String] = []
    private let statusJSON: String

    init(
        statusJSON: String = #"{"daemon":"host-agent","version":"0.1.0","status_schema_version":2,"features":{"bash_auto_notify_runtime_probe":true},"bash_auto_notify_configured":true,"bash_auto_notify_runtime_probe":true}"#
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

struct HostAgentInstallerTests {
    private let runtimeConfig = HostAgentRuntimeConfig(
        hostAgentReleaseTag: "v1.0.19",
        requiredStatusSchemaVersion: 2
    )

    @Test
    func installBashAutoNotifyUsesExpectedRemoteCommand() async throws {
        let ssh = RecordingSSHExecutor()
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        try await installer.installBashAutoNotify(on: connection, minSeconds: 3)

        #expect(ssh.commands.count == 2)
        let installCommand = try #require(ssh.commands.first)
        #expect(installCommand.contains("/bin/sh -c"))
        #expect(installCommand.contains("install-shell-notify --min-seconds 3"))
        #expect(installCommand.contains("XDG_RUNTIME_DIR"))
        #expect(installCommand.contains("DBUS_SESSION_BUS_ADDRESS"))

        let statusCommand = try #require(ssh.commands.last)
        #expect(statusCommand.contains("status --json"))
        #expect(statusCommand.contains("XDG_RUNTIME_DIR"))
        #expect(statusCommand.contains("DBUS_SESSION_BUS_ADDRESS"))
        #expect(!statusCommand.contains("/bin/sh -lc"))
    }

    @Test
    func installBashAutoNotifyClampsMinSecondsToOne() async throws {
        let ssh = RecordingSSHExecutor()
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        try await installer.installBashAutoNotify(on: connection, minSeconds: 0)

        let command = try #require(ssh.commands.first)
        #expect(command.contains("install-shell-notify --min-seconds 1"))
        #expect(command.contains("XDG_RUNTIME_DIR"))
        #expect(command.contains("DBUS_SESSION_BUS_ADDRESS"))
        #expect(ssh.commands.count == 2)
    }

    @Test
    func installBashAutoNotifyFailsWhenRuntimeProbeFails() async throws {
        let ssh = RecordingSSHExecutor(
            statusJSON: #"{"daemon":"host-agent","version":"0.1.0","status_schema_version":2,"features":{"bash_auto_notify_runtime_probe":true},"bash_auto_notify_configured":true,"bash_auto_notify_runtime_probe":false}"#
        )
        let installer = HostAgentInstaller(sshExecutor: ssh, runtimeConfig: runtimeConfig)
        let connection = SSHConnectionSpec(
            host: "example-host",
            port: 22,
            username: "alice",
            secret: .password("secret")
        )

        var didThrow = false
        do {
            try await installer.installBashAutoNotify(on: connection, minSeconds: 3)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test
    func installBashAutoNotifyReportsUnavailableProbeDetail() async throws {
        let ssh = RecordingSSHExecutor(
            statusJSON: #"{"daemon":"host-agent","version":"0.1.0","status_schema_version":2,"features":{"bash_auto_notify_runtime_probe":true},"bash_auto_notify_configured":true,"bash_auto_notify_runtime_probe":null,"bash_runtime_probe_detail":"unavailable:not_found","bash_binary_path":null,"readiness_errors":["bash_auto_notify_runtime_probe_unavailable"]}"#
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
            try await installer.installBashAutoNotify(on: connection, minSeconds: 3)
        } catch {
            message = error.localizedDescription
        }
        #expect(!message.isEmpty)
        #expect(message.contains("unavailable:not_found"))
        #expect(message.contains("readiness_errors=bash_auto_notify_runtime_probe_unavailable"))
    }

    @Test
    func installBashAutoNotifyFailsWhenStatusSchemaIsMissing() async throws {
        let ssh = RecordingSSHExecutor(
            statusJSON: #"{"bash_auto_notify_configured":true,"bash_auto_notify_runtime_probe":true}"#
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
            try await installer.installBashAutoNotify(on: connection, minSeconds: 3)
        } catch {
            message = error.localizedDescription
        }
        #expect(!message.isEmpty)
        #expect(message.contains("status is incompatible"))
    }

    @Test
    func installUsesPinnedHostAgentReleaseTag() async throws {
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
        #expect(command.contains("/releases/download/v1.0.19/host-agent-linux-x86_64-musl.tar.gz"))
        #expect(!command.contains("/releases/latest/download/"))
    }

    @Test
    func installFailsWhenReleaseTagIsMissing() async throws {
        let ssh = RecordingSSHExecutor()
        let badConfig = HostAgentRuntimeConfig(hostAgentReleaseTag: "", requiredStatusSchemaVersion: 2)
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
        #expect(message.contains("release tag is not configured"))
        #expect(ssh.commands.isEmpty)
    }

    @Test
    func installReportsReleaseAssetNotFoundWhenDownloadReturns404() async throws {
        let stderr = """
        curl: (22) The requested URL returned error: 404
        failed to download host-agent archive from 'https://github.com/allenneverland/tmux-chat/releases/download/v1.0.19/host-agent-linux-x86_64-musl.tar.gz'
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
        #expect(message.contains("release_tag=v1.0.19"))
        #expect(message.contains("host-agent-linux-x86_64-musl.tar.gz"))
    }
}
