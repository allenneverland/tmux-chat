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
        let existing = try await detectTmuxChatdExecutable(on: connection)

        do {
            try await installTmuxChatd(on: connection)
        } catch {
            if let existing {
                return existing
            }
            throw error
        }

        if let executable = try await detectTmuxChatdExecutable(on: connection) {
            return executable
        }

        if let existing {
            return existing
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

    func ensureTmuxChatdRunning(
        on connection: SSHConnectionSpec,
        executable: String,
        pushServerBaseURL: String,
        expectedUsername: String
    ) async throws {
        let script = """
        set -eu

        BIN=\(shellQuote(executable))
        PUSH_URL=\(shellQuote(pushServerBaseURL))
        EXPECTED_USER=\(shellQuote(expectedUsername))
        CURRENT_USER="$(id -un)"
        LOG_DIR="$HOME/.local/state/tmux-chatd"
        mkdir -p "$LOG_DIR"

        if [ "$CURRENT_USER" != "$EXPECTED_USER" ]; then
          echo "SSH user mismatch: connected as $CURRENT_USER but expected $EXPECTED_USER" >&2
          exit 1
        fi

        listener_owner() {
          if command -v lsof >/dev/null 2>&1; then
            PID="$(lsof -nP -iTCP:8787 -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
            if [ -n "$PID" ]; then
              ps -o user= -p "$PID" 2>/dev/null | awk '{print $1}' | head -n 1
              return 0
            fi
          fi

          if command -v ss >/dev/null 2>&1; then
            PID="$(ss -ltnp 2>/dev/null | awk '/:8787[[:space:]]/ { print }' | grep -Eo 'pid=[0-9]+' | head -n 1 | cut -d= -f2 || true)"
            if [ -n "$PID" ]; then
              ps -o user= -p "$PID" 2>/dev/null | awk '{print $1}' | head -n 1
              return 0
            fi
          fi

          return 0
        }

        check_ready() {
          if command -v curl >/dev/null 2>&1; then
            CODE="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8787/sessions || true)"
            case "$CODE" in
              200|401|403|404|405)
                return 0
                ;;
            esac
          elif command -v nc >/dev/null 2>&1; then
            nc -z 127.0.0.1 8787 >/dev/null 2>&1 && return 0
          fi
          return 1
        }

        OWNER="$(listener_owner || true)"
        if [ -n "$OWNER" ] && [ "$OWNER" != "$CURRENT_USER" ]; then
          echo "Port 8787 is already served by tmux-chatd user $OWNER, not $CURRENT_USER. Reconnect with SSH user $OWNER or stop the existing service first." >&2
          exit 1
        fi

        USE_SYSTEMD=0
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
          USE_SYSTEMD=1
          mkdir -p "$HOME/.config/systemd/user"
          {
            echo "[Unit]"
            echo "Description=tmux-chatd"
            echo "After=network-online.target"
            echo "Wants=network-online.target"
            echo
            echo "[Service]"
            echo "Type=simple"
            echo "ExecStart=$BIN"
            echo "Restart=always"
            echo "RestartSec=2"
            echo "Environment=TMUX_CHATD_BIND_ADDR=127.0.0.1"
            echo "Environment=TMUX_CHATD_PORT=8787"
            echo "Environment=TMUX_CHATD_DATA_DIR=$HOME/.local/share/tmux-chatd"
            echo "Environment=PUSH_SERVER_BASE_URL=$PUSH_URL"
            echo
            echo "[Install]"
            echo "WantedBy=default.target"
          } > "$HOME/.config/systemd/user/tmux-chatd.service"
          systemctl --user daemon-reload || true
          # Always restart so onboarding picks the newest binary/version.
          systemctl --user enable --now tmux-chatd.service || true
          systemctl --user restart tmux-chatd.service || true
        fi

        if [ "$USE_SYSTEMD" -eq 0 ]; then
          if command -v pgrep >/dev/null 2>&1 && pgrep -f 'tmux-chatd' >/dev/null 2>&1; then
            pkill -f 'tmux-chatd' || true
            sleep 1
          fi
          nohup "$BIN" > "$LOG_DIR/tmux-chatd.log" 2>&1 &
        fi

        OWNER="$(listener_owner || true)"
        if [ -n "$OWNER" ] && [ "$OWNER" != "$CURRENT_USER" ]; then
          echo "tmux-chatd started as unexpected user $OWNER. Expected $CURRENT_USER." >&2
          exit 1
        fi

        ATTEMPT=0
        while [ "$ATTEMPT" -lt 20 ]; do
          if check_ready; then
            exit 0
          fi
          ATTEMPT=$((ATTEMPT + 1))
          sleep 1
        done

        echo "tmux-chatd is installed but not reachable on 127.0.0.1:8787. Check $LOG_DIR/tmux-chatd.log" >&2
        exit 1
        """

        _ = try await sshExecutor.run(command: "/bin/sh -lc \(shellQuote(script))", on: connection)
    }

    private func detectTmuxChatdExecutable(on connection: SSHConnectionSpec) async throws -> String? {
        let script = """
        if [ -x "$HOME/.local/bin/tmux-chatd" ]; then
          echo "$HOME/.local/bin/tmux-chatd"
        elif command -v tmux-chatd >/dev/null 2>&1; then
          command -v tmux-chatd
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
