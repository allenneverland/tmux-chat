//
//  HostAgentInstaller.swift
//  Reattach
//

import Foundation

enum HostAgentInstallerError: LocalizedError {
    case unsupportedPlatform(String)
    case missingReattachd

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let value):
            return "Unsupported remote platform: \(value)"
        case .missingReattachd:
            return "reattachd is not installed on remote host"
        }
    }
}

struct HostAgentPlatform: Equatable {
    let os: String
    let arch: String
    let releaseAssetName: String
}

final class HostAgentInstaller {
    private let sshExecutor: SSHCommandExecuting

    init(sshExecutor: SSHCommandExecuting) {
        self.sshExecutor = sshExecutor
    }

    func ensureReattachdInstalled(on connection: SSHConnectionSpec) async throws {
        _ = try await sshExecutor.run(
            command: "command -v reattachd >/dev/null 2>&1",
            on: connection
        )
    }

    func detectPlatform(on connection: SSHConnectionSpec) async throws -> HostAgentPlatform {
        let result = try await sshExecutor.run(
            command: "uname -s && uname -m",
            on: connection
        )
        let values = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard values.count >= 2 else {
            throw HostAgentInstallerError.unsupportedPlatform(result.stdout)
        }

        let osRaw = values[0].lowercased()
        let archRaw = values[1].lowercased()

        switch (osRaw, archRaw) {
        case ("darwin", "arm64"), ("darwin", "aarch64"):
            return HostAgentPlatform(os: "darwin", arch: "aarch64", releaseAssetName: "host-agent-darwin-aarch64.tar.gz")
        case ("darwin", "x86_64"):
            return HostAgentPlatform(os: "darwin", arch: "x86_64", releaseAssetName: "host-agent-darwin-x86_64.tar.gz")
        case ("linux", "x86_64"):
            return HostAgentPlatform(os: "linux", arch: "x86_64", releaseAssetName: "host-agent-linux-x86_64-musl.tar.gz")
        case ("linux", "aarch64"), ("linux", "arm64"):
            return HostAgentPlatform(os: "linux", arch: "aarch64", releaseAssetName: "host-agent-linux-aarch64-gnu.tar.gz")
        default:
            throw HostAgentInstallerError.unsupportedPlatform("\(values[0]) \(values[1])")
        }
    }

    func install(
        on connection: SSHConnectionSpec,
        pushServerBaseURL: String,
        releaseAssetName: String
    ) async throws {
        let url = "https://github.com/kumabook/Reattach/releases/latest/download/\(releaseAssetName)"
        let script = """
        set -eu
        TMPDIR="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR"' EXIT

        download() {
          if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$1" -o "$2"
            return 0
          fi
          if command -v wget >/dev/null 2>&1; then
            wget -qO "$2" "$1"
            return 0
          fi
          return 1
        }

        mkdir -p "$HOME/.local/bin"
        download \(shellQuote(url)) "$TMPDIR/host-agent.tgz"
        tar -xzf "$TMPDIR/host-agent.tgz" -C "$TMPDIR"

        BIN="$(find "$TMPDIR" -type f -name host-agent | head -n 1)"
        if [ -z "$BIN" ]; then
          echo "host-agent binary not found in archive" >&2
          exit 1
        fi

        install -m 755 "$BIN" "$HOME/.local/bin/host-agent"
        "$HOME/.local/bin/host-agent" install --push-server-base-url \(shellQuote(pushServerBaseURL))
        """

        _ = try await sshExecutor.run(command: "/bin/sh -lc \(shellQuote(script))", on: connection)
    }

    func pair(
        on connection: SSHConnectionSpec,
        pairingToken: String,
        pushServerBaseURL: String
    ) async throws -> String {
        let command = "\"$HOME/.local/bin/host-agent\" pair --token \(shellQuote(pairingToken)) --push-server-base-url \(shellQuote(pushServerBaseURL)) --json"
        let result = try await sshExecutor.run(command: "/bin/sh -lc \(shellQuote(command))", on: connection)
        return result.stdout
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
