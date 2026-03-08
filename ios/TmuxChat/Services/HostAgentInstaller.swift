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

struct HostAgentRuntimeConfig: Equatable {
    let hostAgentReleaseTag: String
    let requiredStatusSchemaVersion: Int

    static func fromBundle(_ bundle: Bundle = .main) -> HostAgentRuntimeConfig {
        let releaseTag = (bundle.object(forInfoDictionaryKey: "HostAgentReleaseTag") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requiredSchemaValue = bundle.object(forInfoDictionaryKey: "HostAgentRequiredStatusSchemaVersion")

        let requiredStatusSchemaVersion: Int
        if let number = requiredSchemaValue as? NSNumber {
            requiredStatusSchemaVersion = number.intValue
        } else if let string = requiredSchemaValue as? String {
            requiredStatusSchemaVersion = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else {
            requiredStatusSchemaVersion = 0
        }

        return HostAgentRuntimeConfig(
            hostAgentReleaseTag: releaseTag,
            requiredStatusSchemaVersion: requiredStatusSchemaVersion
        )
    }
}

final class HostAgentInstaller {
    private let sshExecutor: SSHCommandExecuting
    private let runtimeConfig: HostAgentRuntimeConfig

    private struct HostAgentStatusResponse: Decodable {
        let daemon: String?
        let version: String?
        let statusSchemaVersion: Int?
        let notificationReady: Bool?
        let readinessErrors: [String]?

        let paired: Bool?
        let socketConnectable: Bool?
        let tmuxHookActive: Bool?
        let tmuxMonitorBell: String?
        let tmuxBellAction: String?
        let serviceActive: Bool?

        enum CodingKeys: String, CodingKey {
            case daemon
            case version
            case statusSchemaVersion = "status_schema_version"
            case notificationReady = "notification_ready"
            case readinessErrors = "readiness_errors"
            case paired
            case socketConnectable = "socket_connectable"
            case tmuxHookActive = "tmux_hook_active"
            case tmuxMonitorBell = "tmux_monitor_bell"
            case tmuxBellAction = "tmux_bell_action"
            case serviceActive = "service_active"
        }
    }

    init(sshExecutor: SSHCommandExecuting, runtimeConfig: HostAgentRuntimeConfig = .fromBundle()) {
        self.sshExecutor = sshExecutor
        self.runtimeConfig = runtimeConfig
    }

    func ensureTmuxChatdInstalled(on connection: SSHConnectionSpec) async throws -> String {
        do {
            try await installTmuxChatd(on: connection)
        } catch {
            throw mapTmuxChatdInstallFailure(error)
        }

        if let executable = try await detectTmuxChatdExecutable(on: connection) {
            return executable
        }

        throw HostAgentInstallerError.missingTmuxChatd
    }

    func detectPlatform(on connection: SSHConnectionSpec) async throws -> HostAgentPlatform {
        let result = try await sshExecutor.run(
            command: "uname -s && uname -m",
            on: connection,
            timeoutProfile: .standard
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
        let releaseSelector = try requireHostAgentReleaseSelector()
        let url = hostAgentReleaseDownloadURL(
            releaseSelector: releaseSelector,
            releaseAssetName: releaseAssetName
        )
        let script = """
        set -eu
        TMPDIR="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR"' EXIT

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

        mkdir -p "$HOME/.local/bin"
        if ! download \(shellQuote(url)) "$TMPDIR/host-agent.tgz"; then
          echo "failed to download host-agent archive from \(shellQuote(url)) (release_selector=\(shellQuote(releaseSelector)), asset=\(shellQuote(releaseAssetName)))" >&2
          exit 1
        fi
        if [ ! -s "$TMPDIR/host-agent.tgz" ]; then
          echo "host-agent archive download produced empty file (release_selector=\(shellQuote(releaseSelector)), asset=\(shellQuote(releaseAssetName)))" >&2
          exit 1
        fi
        tar -xzf "$TMPDIR/host-agent.tgz" -C "$TMPDIR"

        BIN="$(find "$TMPDIR" -type f -name host-agent | head -n 1)"
        if [ -z "$BIN" ]; then
          echo "host-agent binary not found in archive" >&2
          exit 1
        fi

        install -m 755 "$BIN" "$HOME/.local/bin/host-agent"
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
          export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        fi
        "$HOME/.local/bin/host-agent" install --push-server-base-url \(shellQuote(pushServerBaseURL))
        """

        do {
            _ = try await sshExecutor.run(
                command: "/bin/sh -c \(shellQuote(script))",
                on: connection,
                timeoutProfile: .long
            )
        } catch {
            throw mapInstallFailure(
                error,
                releaseSelector: releaseSelector,
                releaseAssetName: releaseAssetName,
                url: url
            )
        }
    }

    func pair(
        on connection: SSHConnectionSpec,
        pairingToken: String,
        pushServerBaseURL: String
    ) async throws -> String {
        let command = hostAgentCommand(
            "pair --token \(shellQuote(pairingToken)) --push-server-base-url \(shellQuote(pushServerBaseURL)) --json"
        )
        let result = try await sshExecutor.run(
            command: command,
            on: connection,
            timeoutProfile: .long
        )
        return result.stdout
    }

    func verifyHostAgentReadiness(on connection: SSHConnectionSpec) async throws {
        let command = hostAgentCommand("status --json")
        let result = try await sshExecutor.run(
            command: command,
            on: connection,
            timeoutProfile: .standard
        )
        let status = try decodeJSONFromOutput(result.stdout, as: HostAgentStatusResponse.self)
        try assertStatusCompatibility(status)

        let inferredReady = (status.paired == true)
            && (status.socketConnectable == true)
            && (status.tmuxHookActive == true)
            && (status.tmuxMonitorBell == "on")
            && (status.tmuxBellAction == "any")
            && (status.serviceActive == true)
        let ready = status.notificationReady ?? inferredReady
        guard ready else {
            let details: String
            if let errors = status.readinessErrors, !errors.isEmpty {
                details = errors.joined(separator: ", ")
            } else {
                let serviceActiveText = status.serviceActive.map { $0 ? "true" : "false" } ?? "unknown"
                details =
                    "paired=\(status.paired == true), socket_connectable=\(status.socketConnectable == true), tmux_hook_active=\(status.tmuxHookActive == true), tmux_monitor_bell=\(status.tmuxMonitorBell ?? "unknown"), tmux_bell_action=\(status.tmuxBellAction ?? "unknown"), service_active=\(serviceActiveText)"
            }
            throw APIError.serverError("Host-agent notifications are not ready (\(details)).")
        }
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
          echo "reason=ssh_user_mismatch SSH user mismatch: connected as $CURRENT_USER but expected $EXPECTED_USER" >&2
          exit 1
        fi

        USE_SYSTEMD=0
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
          USE_SYSTEMD=1
        fi

        listener_pid() {
          if command -v lsof >/dev/null 2>&1; then
            PID="$(lsof -nP -iTCP:8787 -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
            if [ -n "$PID" ]; then
              echo "$PID"
              return 0
            fi
          fi

          if command -v ss >/dev/null 2>&1; then
            PID="$(ss -ltnp 2>/dev/null | awk '/:8787[[:space:]]/ { print }' | grep -Eo 'pid=[0-9]+' | head -n 1 | cut -d= -f2 || true)"
            if [ -n "$PID" ]; then
              echo "$PID"
              return 0
            fi
          fi

          return 0
        }

        listener_owner() {
          PID="$(listener_pid || true)"
          if [ -n "$PID" ]; then
            ps -o user= -p "$PID" 2>/dev/null | awk '{print $1}' | head -n 1
          fi
          return 0
        }

        listener_executable() {
          PID="$(listener_pid || true)"
          if [ -z "$PID" ]; then
            return 0
          fi
          if [ -r "/proc/$PID/exe" ]; then
            readlink "/proc/$PID/exe" 2>/dev/null || true
            return 0
          fi
          ps -o command= -p "$PID" 2>/dev/null | awk '{print $1}' | head -n 1
          return 0
        }

        canonical_path() {
          TARGET="$1"
          if command -v readlink >/dev/null 2>&1; then
            CANON="$(readlink -f "$TARGET" 2>/dev/null || true)"
            if [ -n "$CANON" ]; then
              echo "$CANON"
              return 0
            fi
          fi
          echo "$TARGET"
          return 0
        }

        binary_identity_ok() {
          EXE="$1"
          [ -n "$EXE" ] || return 1
          if printf "%s" "$EXE" | grep -Eq ' \\(deleted\\)$'; then
            return 1
          fi
          EXE_CANON="$(canonical_path "$EXE")"
          BIN_CANON="$(canonical_path "$BIN")"
          [ "$EXE_CANON" = "$BIN_CANON" ]
        }

        read_healthz() {
          if ! command -v curl >/dev/null 2>&1; then
            return 1
          fi
          curl -fsS http://127.0.0.1:8787/healthz 2>/dev/null
        }

        healthz_ok() {
          HEALTHZ_JSON="$(read_healthz || true)"
          [ -n "$HEALTHZ_JSON" ] || return 1

          if command -v jq >/dev/null 2>&1; then
            echo "$HEALTHZ_JSON" | jq -e '.status == "ok"' >/dev/null 2>&1
            return $?
          fi

          echo "$HEALTHZ_JSON" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'
        }

        healthz_summary() {
          HEALTHZ_JSON="$(read_healthz || true)"
          if [ -z "$HEALTHZ_JSON" ]; then
            echo "healthz_status=unavailable"
            return 0
          fi

          if command -v jq >/dev/null 2>&1; then
            STATUS="$(echo "$HEALTHZ_JSON" | jq -r '.status // "nil"' 2>/dev/null || true)"
            if [ -n "$STATUS" ]; then
              echo "healthz_status=$STATUS"
              return 0
            fi
          fi

          ONE_LINE="$(printf "%s" "$HEALTHZ_JSON" | tr '\n' ' ' | tr -s ' ')"
          echo "healthz_raw=$ONE_LINE"
          return 0
        }

        read_capabilities() {
          if ! command -v curl >/dev/null 2>&1; then
            return 1
          fi
          curl -fsS http://127.0.0.1:8787/capabilities 2>/dev/null
        }

        capabilities_contract_ok() {
          CAPS_JSON="$(read_capabilities || true)"
          [ -n "$CAPS_JSON" ] || return 1

          if command -v jq >/dev/null 2>&1; then
            echo "$CAPS_JSON" \
              | jq -e '.daemon == "tmux-chatd" and .capabilities_schema_version >= 5 and .features.input_events_v1.enabled == true and .endpoints.pane_input_events == true' >/dev/null 2>&1
            return $?
          fi

          echo "$CAPS_JSON" | grep -Eq '"daemon"[[:space:]]*:[[:space:]]*"tmux-chatd"' || return 1
          echo "$CAPS_JSON" | grep -Eq '"capabilities_schema_version"[[:space:]]*:[[:space:]]*[5-9][0-9]*' || return 1
          echo "$CAPS_JSON" | grep -Eq '"input_events_v1"[[:space:]]*:[[:space:]]*\\{' || return 1
          echo "$CAPS_JSON" | grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true' || return 1
          echo "$CAPS_JSON" | grep -Eq '"pane_input_events"[[:space:]]*:[[:space:]]*true' || return 1
          return 0
        }

        capabilities_summary() {
          CAPS_JSON="$(read_capabilities || true)"
          if [ -z "$CAPS_JSON" ]; then
            echo "capabilities=unavailable"
            return 0
          fi

          if command -v jq >/dev/null 2>&1; then
            SUMMARY="$(echo "$CAPS_JSON" | jq -r '"daemon=\\(.daemon // "nil"),capabilities_schema_version=\\(.capabilities_schema_version // "nil"),input_events_enabled=\\(.features.input_events_v1.enabled // "nil"),pane_input_events=\\(.endpoints.pane_input_events // "nil"),max_batch=\\(.features.input_events_v1.max_batch // "nil"),supports_repeat=\\(.features.input_events_v1.supports_repeat // "nil")"' 2>/dev/null || true)"
            if [ -n "$SUMMARY" ]; then
              echo "$SUMMARY"
              return 0
            fi
          fi

          ONE_LINE="$(printf "%s" "$CAPS_JSON" | tr '\n' ' ' | tr -s ' ')"
          echo "capabilities_raw=$ONE_LINE"
          return 0
        }

        wait_for_port_release() {
          ATTEMPT=0
          while [ "$ATTEMPT" -lt 15 ]; do
            PID="$(listener_pid || true)"
            if [ -z "$PID" ]; then
              return 0
            fi
            ATTEMPT=$((ATTEMPT + 1))
            sleep 1
          done
          return 1
        }

        cleanup_existing_listener() {
          REASON_HINT="$1"

          if [ "$USE_SYSTEMD" -eq 1 ]; then
            systemctl --user stop tmux-chatd.service >/dev/null 2>&1 || true
            systemctl --user reset-failed tmux-chatd.service >/dev/null 2>&1 || true
          fi

          PID="$(listener_pid || true)"
          if [ -n "$PID" ]; then
            OWNER="$(listener_owner || true)"
            if [ -n "$OWNER" ] && [ "$OWNER" != "$CURRENT_USER" ]; then
              echo "reason=port_owned_by_other_user Port 8787 is already served by tmux-chatd user $OWNER, not $CURRENT_USER. Reconnect with SSH user $OWNER or stop the existing service first." >&2
              return 1
            fi
            kill "$PID" 2>/dev/null || true
            sleep 1
            PID="$(listener_pid || true)"
            if [ -n "$PID" ]; then
              kill -9 "$PID" 2>/dev/null || true
            fi
          fi

          if command -v pgrep >/dev/null 2>&1; then
            for PID in $(pgrep -x tmux-chatd 2>/dev/null || true); do
              OWNER="$(ps -o user= -p "$PID" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
              if [ -z "$OWNER" ] || [ "$OWNER" = "$CURRENT_USER" ]; then
                kill "$PID" 2>/dev/null || true
              fi
            done
          fi

          if ! wait_for_port_release; then
            echo "reason=stale_cleanup_failed tmux-chatd stale cleanup failed to release 127.0.0.1:8787 (reason_hint=$REASON_HINT)." >&2
            return 1
          fi

          return 0
        }

        PID="$(listener_pid || true)"
        if [ -n "$PID" ]; then
          OWNER="$(listener_owner || true)"
          if [ -n "$OWNER" ] && [ "$OWNER" != "$CURRENT_USER" ]; then
            echo "reason=port_owned_by_other_user Port 8787 is already served by tmux-chatd user $OWNER, not $CURRENT_USER. Reconnect with SSH user $OWNER or stop the existing service first." >&2
            exit 1
          fi

          EXE="$(listener_executable || true)"
          PRECHECK_REASON=""
          if printf "%s" "$EXE" | grep -Eq ' \\(deleted\\)$'; then
            PRECHECK_REASON="stale_deleted_binary"
          elif ! binary_identity_ok "$EXE"; then
            PRECHECK_REASON="binary_identity_mismatch"
          elif ! capabilities_contract_ok; then
            PRECHECK_REASON="contract_mismatch"
          fi

          if [ -n "$PRECHECK_REASON" ]; then
            if ! cleanup_existing_listener "$PRECHECK_REASON"; then
              exit 1
            fi
          fi
        fi

        if [ "$USE_SYSTEMD" -eq 1 ]; then
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
          systemctl --user daemon-reload
          # Always restart so onboarding picks the newest binary/version.
          systemctl --user enable --now tmux-chatd.service
          systemctl --user restart tmux-chatd.service
        else
          cleanup_existing_listener "pre_start_nosystemd" || true
          nohup "$BIN" > "$LOG_DIR/tmux-chatd.log" 2>&1 &
        fi

        ATTEMPT=0
        FAILURE_REASON="unknown"
        while [ "$ATTEMPT" -lt 30 ]; do
          PID="$(listener_pid || true)"
          OWNER="$(listener_owner || true)"
          EXE="$(listener_executable || true)"

          if [ -n "$OWNER" ] && [ "$OWNER" != "$CURRENT_USER" ]; then
            FAILURE_REASON="port_owned_by_other_user"
          elif [ -z "$PID" ]; then
            FAILURE_REASON="listener_unavailable"
          elif printf "%s" "$EXE" | grep -Eq ' \\(deleted\\)$'; then
            FAILURE_REASON="stale_deleted_binary"
          elif ! binary_identity_ok "$EXE"; then
            FAILURE_REASON="binary_identity_mismatch"
          elif ! healthz_ok; then
            FAILURE_REASON="healthz_unreachable"
          elif ! capabilities_contract_ok; then
            FAILURE_REASON="contract_mismatch"
          else
            exit 0
          fi

          ATTEMPT=$((ATTEMPT + 1))
          sleep 1
        done

        PID="${PID:-$(listener_pid || true)}"
        OWNER="${OWNER:-$(listener_owner || true)}"
        EXE="${EXE:-$(listener_executable || true)}"
        HEALTHZ="$(healthz_summary || true)"
        SUMMARY="$(capabilities_summary || true)"
        [ -n "$PID" ] || PID="none"
        [ -n "$OWNER" ] || OWNER="unknown"
        [ -n "$EXE" ] || EXE="unknown"
        [ -n "$HEALTHZ" ] || HEALTHZ="healthz_status=unavailable"
        [ -n "$SUMMARY" ] || SUMMARY="capabilities=unavailable"
        echo "reason=$FAILURE_REASON tmux-chatd contract verification failed on 127.0.0.1:8787 (pid=$PID owner=$OWNER executable=$EXE $HEALTHZ $SUMMARY). Check $LOG_DIR/tmux-chatd.log and service status." >&2
        exit 1
        """

        do {
            _ = try await sshExecutor.run(
                command: "/bin/sh -c \(shellQuote(script))",
                on: connection,
                timeoutProfile: .long
            )
        } catch {
            throw mapTmuxChatdStartFailure(error)
        }
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

        let result = try await sshExecutor.run(
            command: "/bin/sh -c \(shellQuote(script))",
            on: connection,
            timeoutProfile: .quick
        )
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

        _ = try await sshExecutor.run(
            command: "/bin/sh -c \(shellQuote(script))",
            on: connection,
            timeoutProfile: .long
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func hostAgentCommand(_ args: String) -> String {
        let script = """
        set -eu
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
          export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        fi
        "$HOME/.local/bin/host-agent" \(args)
        """
        return "/bin/sh -c \(shellQuote(script))"
    }

    private func requireHostAgentReleaseSelector() throws -> String {
        let value = runtimeConfig.hostAgentReleaseTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else {
            throw APIError.serverError(
                "Host-agent release selector is not configured. Set Info.plist HostAgentReleaseTag to 'latest' or a concrete version tag (for example v1.0.20)."
            )
        }

        if value == "latest" {
            return value
        }

        guard value.first == "v" else {
            throw APIError.serverError(
                "Host-agent release selector must be 'latest' or start with 'v' (current: \(value))."
            )
        }
        return value
    }

    private func hostAgentReleaseDownloadURL(releaseSelector: String, releaseAssetName: String) -> String {
        if releaseSelector == "latest" {
            return "https://github.com/allenneverland/tmux-chat/releases/latest/download/\(releaseAssetName)"
        }
        return "https://github.com/allenneverland/tmux-chat/releases/download/\(releaseSelector)/\(releaseAssetName)"
    }

    private func mapInstallFailure(
        _ error: Error,
        releaseSelector: String,
        releaseAssetName: String,
        url: String
    ) -> Error {
        guard case .commandFailed(_, let stderr) = error as? SSHCommandExecutorError else {
            return error
        }

        let lowercased = stderr.lowercased()
        let is404 = (lowercased.contains("curl: (22)") && lowercased.contains("404"))
            || lowercased.contains("requested url returned error: 404")
            || lowercased.contains(" 404 ")
        if is404 {
            return APIError.serverError(
                "Host-agent release asset not found (release_selector=\(releaseSelector), asset=\(releaseAssetName)). Verify the GitHub release selector and assets exist, then update Info.plist HostAgentReleaseTag if needed. URL: \(url)"
            )
        }

        return error
    }

    private func mapTmuxChatdInstallFailure(_ error: Error) -> Error {
        guard case .commandFailed(_, let stderr) = error as? SSHCommandExecutorError else {
            return APIError.serverError(
                "tmux-chatd latest install/upgrade failed; onboarding stops until host tmux-chatd is upgraded. Error: \(error.localizedDescription)"
            )
        }

        let lowercased = stderr.lowercased()
        let is404 = (lowercased.contains("curl: (22)") && lowercased.contains("404"))
            || lowercased.contains("requested url returned error: 404")
            || lowercased.contains(" 404 ")
        if is404 {
            return APIError.serverError(
                "tmux-chatd release asset not found for this host platform while resolving latest release. Verify GitHub release assets, then retry onboarding."
            )
        }

        let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.isEmpty {
            return APIError.serverError(
                "tmux-chatd latest install/upgrade failed; onboarding stops until host tmux-chatd is upgraded."
            )
        }

        return APIError.serverError(
            "tmux-chatd latest install/upgrade failed; onboarding stops until host tmux-chatd is upgraded. Details: \(details)"
        )
    }

    private func mapTmuxChatdStartFailure(_ error: Error) -> Error {
        guard case .commandFailed(_, let stderr) = error as? SSHCommandExecutorError else {
            return error
        }

        let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !details.isEmpty else {
            return error
        }

        if details.contains("reason=port_owned_by_other_user") {
            return APIError.serverError(
                "Port 8787 is already served by a different SSH user. Reconnect with that SSH user or stop the existing tmux-chatd service. Details: \(details)"
            )
        }

        if details.contains("reason=ssh_user_mismatch") {
            return APIError.serverError(
                "SSH user mismatch while starting tmux-chatd. Verify the configured username and reconnect. Details: \(details)"
            )
        }

        if details.contains("reason=stale_cleanup_failed")
            || details.contains("reason=stale_deleted_binary")
            || details.contains("reason=binary_identity_mismatch")
        {
            return APIError.serverError(
                "tmux-chatd stale listener cleanup/restart did not converge to the expected binary identity. Details: \(details)"
            )
        }

        if details.contains("reason=healthz_unreachable") {
            return APIError.serverError(
                "tmux-chatd started but /healthz did not become reachable on 127.0.0.1:8787. Details: \(details)"
            )
        }

        if details.contains("reason=contract_mismatch") {
            return APIError.serverError(
                "tmux-chatd is reachable but does not satisfy the required control-plane contract. Details: \(details)"
            )
        }

        return error
    }

    private func requiredHostAgentStatusSchemaVersion() throws -> Int {
        let value = runtimeConfig.requiredStatusSchemaVersion
        guard value > 0 else {
            throw APIError.serverError(
                "Host-agent status schema requirement is not configured. Set Info.plist HostAgentRequiredStatusSchemaVersion to a positive integer."
            )
        }
        return value
    }

    private func assertStatusCompatibility(_ status: HostAgentStatusResponse) throws {
        let requiredSchema = try requiredHostAgentStatusSchemaVersion()
        let releaseSelector = try requireHostAgentReleaseSelector()
        let remoteVersion = status.version ?? "unknown"
        let remoteSchema = status.statusSchemaVersion.map { String($0) } ?? "unknown"

        guard status.daemon == "host-agent" else {
            throw APIError.serverError(
                "Host-agent status is incompatible (daemon=\(status.daemon ?? "unknown"), version=\(remoteVersion), required_schema=\(requiredSchema), release_selector=\(releaseSelector))."
            )
        }

        guard let schema = status.statusSchemaVersion, schema >= requiredSchema else {
            throw APIError.serverError(
                "Host-agent status schema is incompatible (remote_schema=\(remoteSchema), required_schema=\(requiredSchema), version=\(remoteVersion), release_selector=\(releaseSelector))."
            )
        }

    }

    private func decodeJSONFromOutput<T: Decodable>(_ output: String, as type: T.Type) throws -> T {
        if let directData = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let value = try? JSONDecoder().decode(type, from: directData) {
            return value
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode(type, from: data) {
                return decoded
            }
        }

        throw APIError.decodingError(NSError(domain: "SSHOutput", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Unable to parse JSON from remote command output"
        ]))
    }
}
