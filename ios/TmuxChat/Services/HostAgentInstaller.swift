//
//  HostAgentInstaller.swift
//  TmuxChat
//

import Foundation

enum HostAgentInstallerError: LocalizedError {
    case unsupportedPlatform(String)
    case missingTmuxChatd

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let value):
            return "Unsupported remote platform: \(value)"
        case .missingTmuxChatd:
            return "tmux-chatd is not installed on remote host"
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

    func ensureTmuxChatdInstalled(on connection: SSHConnectionSpec) async throws -> String {
        if let executable = try await detectTmuxChatdExecutable(on: connection) {
            return executable
        }

        try await installTmuxChatd(on: connection)

        if let executable = try await detectTmuxChatdExecutable(on: connection) {
            return executable
        }

        throw HostAgentInstallerError.missingTmuxChatd
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
        let url = "https://github.com/allenneverland/tmux-chat/releases/latest/download/\(releaseAssetName)"
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

    private func detectTmuxChatdExecutable(on connection: SSHConnectionSpec) async throws -> String? {
        let script = """
        if command -v tmux-chatd >/dev/null 2>&1; then
          command -v tmux-chatd
        elif [ -x "$HOME/.local/bin/tmux-chatd" ]; then
          echo "$HOME/.local/bin/tmux-chatd"
        fi
        exit 0
        """

        let result = try await sshExecutor.run(command: "/bin/sh -lc \(shellQuote(script))", on: connection)
        let executable = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return executable.isEmpty ? nil : executable
    }

    private func installTmuxChatd(on connection: SSHConnectionSpec) async throws {
        let script = """
        set -eu
        TMPDIR="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR"' EXIT

        REPO="allenneverland/tmux-chat"

        OS="$(uname -s)"
        case "$OS" in
          Linux)  OS_NAME="linux" ;;
          Darwin) OS_NAME="darwin" ;;
          *) echo "Unsupported OS: $OS" >&2; exit 1 ;;
        esac

        ARCH="$(uname -m)"
        case "$ARCH" in
          x86_64) ARCH_NAME="x86_64" ;;
          aarch64|arm64) ARCH_NAME="aarch64" ;;
          *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
        esac

        case "$OS_NAME-$ARCH_NAME" in
          linux-x86_64)
            CANDIDATES="linux-x86_64-gnu linux-x86_64-musl linux-x86_64 linux-amd64-gnu linux-amd64-musl linux-amd64"
            ;;
          linux-aarch64)
            CANDIDATES="linux-aarch64-gnu linux-aarch64-musl linux-aarch64 linux-arm64-gnu linux-arm64-musl linux-arm64"
            ;;
          darwin-aarch64)
            CANDIDATES="darwin-aarch64 darwin-arm64"
            ;;
          darwin-x86_64)
            CANDIDATES="darwin-x86_64 darwin-amd64"
            ;;
          *)
            echo "Unsupported platform: $OS_NAME-$ARCH_NAME" >&2
            exit 1
            ;;
        esac

        download() {
          if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$1" -o "$2"
            return $?
          fi
          if command -v wget >/dev/null 2>&1; then
            wget -qO "$2" "$1"
            return $?
          fi
          return 1
        }

        BASE_URL="https://github.com/$REPO/releases/latest/download"
        SELECTED=""
        for PLATFORM in $CANDIDATES; do
          URL="$BASE_URL/tmux-chatd-$PLATFORM.tar.gz"
          if download "$URL" "$TMPDIR/tmux-chatd.tgz"; then
            SELECTED="$URL"
            break
          fi
        done

        if [ -z "$SELECTED" ]; then
          RELEASES_API="https://api.github.com/repos/$REPO/releases?per_page=20"
          if command -v curl >/dev/null 2>&1; then
            RELEASES_META="$(curl -fsSL "$RELEASES_API" || true)"
          else
            RELEASES_META="$(wget -qO- "$RELEASES_API" || true)"
          fi

          if [ -n "$RELEASES_META" ]; then
            URLS="$(printf "%s" "$RELEASES_META" | grep -Eo "https://github.com/$REPO/releases/download/[^\"]+/tmux-chatd-[^\"]+\\.tar\\.gz" || true)"
            for PLATFORM in $CANDIDATES; do
              URL="$(printf "%s\n" "$URLS" | grep "/tmux-chatd-$PLATFORM\\.tar\\.gz$" | head -n 1 || true)"
              if [ -n "$URL" ] && download "$URL" "$TMPDIR/tmux-chatd.tgz"; then
                SELECTED="$URL"
                break
              fi
            done
          fi
        fi

        if [ -z "$SELECTED" ]; then
          echo "Could not find a matching tmux-chatd release asset for $OS_NAME-$ARCH_NAME (candidates: $CANDIDATES)" >&2
          exit 1
        fi

        tar -xzf "$TMPDIR/tmux-chatd.tgz" -C "$TMPDIR"

        BIN="$(find "$TMPDIR" -type f -name tmux-chatd | head -n 1)"
        if [ -z "$BIN" ]; then
          echo "tmux-chatd binary not found in archive" >&2
          exit 1
        fi

        mkdir -p "$HOME/.local/bin"
        install -m 755 "$BIN" "$HOME/.local/bin/tmux-chatd"
        "$HOME/.local/bin/tmux-chatd" --version >/dev/null 2>&1
        """

        _ = try await sshExecutor.run(command: "/bin/sh -lc \(shellQuote(script))", on: connection)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
