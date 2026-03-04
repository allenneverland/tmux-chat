# Reattach

[English](./README.md) | [繁體中文](./README.zh-TW.md)

**Reattach** is a remote tmux client for iOS.
Control your Mac/Linux tmux sessions from anywhere, and receive push notifications when tmux bell or coding-agent events happen.

## Flag Day Migration Notice

This repository has migrated to SSH onboarding + host-agent pairing.

- QR onboarding is removed.
- Cloudflare Access Service Token compatibility mode is removed.
- Claude/Codex `notify/hooks` compatibility is preserved.

See the announcement: `docs/breaking-changes-flag-day-2026.md`.

## Architecture

Reattach now has two paths that work together:

1. Control plane (iOS -> reattachd -> tmux)
2. Notification plane (tmux bell / agent hook -> host-agent or reattachd notify -> push-server -> APNs -> iOS)

```text
Control Plane
------------
iOS App --HTTPS--> reattachd --local--> tmux

Notification Plane
------------------
tmux alert-bell --> host-agent --> push-server --> APNs --> iOS
Claude/Codex hook --> reattachd notify --> push-server --> APNs --> iOS
```

## Components

| Component | Description |
|-----------|-------------|
| `reattachd` | Rust daemon exposing tmux control APIs (`sessions` / `panes`) |
| `host-agent` | Host-side relay agent that reports tmux bell events to push-server |
| `push-server` | APNs delivery service (pairing, device registration, mute rules, metrics) |
| `ios/` | iOS app (SSH onboarding, remote tmux control, notification routing) |
| `launchd/` | launchd templates for host services |
| `ops/observability/` | Prometheus alert rules + Grafana dashboard templates |

## Requirements

- macOS or Linux host
- [tmux](https://github.com/tmux/tmux)
- iOS device with notification permission enabled
- SSH access from iOS device to host (network path is user choice: VPN, Tailscale, tunnel, etc.)

Full deployment guide (Traditional Chinese):
- `docs/deployment-three-systems.zh-TW.md`

## Quick Start

### 1. Install reattachd on the host

Option A: Homebrew (macOS)

```bash
brew tap allenneverland/reattach
brew install reattachd
brew services start reattachd
```

Option B: install script (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/allenneverland/Reattach/main/install.sh | sh
```

### 2. Start reattachd service

macOS (launchd example):

```bash
mkdir -p ~/Library/Logs/Reattach
# create and load ~/Library/LaunchAgents/com.allenneverland.reattachd.plist
launchctl load ~/Library/LaunchAgents/com.allenneverland.reattachd.plist
```

Linux (systemd example):

```bash
# create and enable /etc/systemd/system/reattachd.service
sudo systemctl daemon-reload
sudo systemctl enable --now reattachd
```

### 3. Choose network path for the control URL

Examples:

- Local network: `http://192.168.x.x:8787`
- VPN/Tailscale: `http://<private-ip>:8787`
- Reverse proxy/tunnel with TLS: `https://your-domain.example.com`

### 4. Add server from iOS via SSH onboarding

In the iOS app:

1. Tap `Add Server via SSH`.
2. Enter control plane URL (reattachd URL).
3. Enter SSH host/user/port and authentication.
4. Continue setup.

The app will:

- verify SSH access
- install `host-agent` remotely
- issue control credentials (`reattachd devices issue --json` on host)
- run push pairing and APNs registration
- save server configuration and verify tmux API

### 5. Optional: coding-agent notification hooks

Auto install:

```bash
reattachd hooks install
```

Manual setup:

- Claude Code (`~/.claude/settings.json`):
  - `hooks.Stop` matcher `""` command `reattachd notify`
  - `hooks.Notification` matcher `"permission_prompt"` command `reattachd notify`
- Codex (`~/.codex/config.toml`, top-level):

```toml
notify = ["reattachd", "notify"]
```

## Advanced: Manual Device Registration (Troubleshooting)

If SSH onboarding is temporarily unavailable, you can issue credentials manually on host:

```bash
reattachd devices issue --name "<device-name>" --json
```

Then add the server in app using:

- `server_url`
- `device_id`
- `device_token`

## Development

### Requirements

- [Rust](https://rustup.rs/)
- Xcode (for iOS)
- Apple Developer account (for APNs testing)

### Build

```bash
git clone https://github.com/allenneverland/Reattach.git
cd Reattach

cp config.local.mk.sample config.local.mk
cp ios/Reattach/Config.xcconfig.sample ios/Reattach/Config.xcconfig

make build
make install
make start
```

### Local config

`config.local.mk`:

```makefile
PUSH_SERVER_BASE_URL = http://127.0.0.1:8790
PUSH_SERVER_COMPAT_NOTIFY_TOKEN = CHANGE_ME
```

`ios/Reattach/Config.xcconfig`:

```xcconfig
BASE_URL = https:/$()/your-domain.example.com
PUSH_SERVER_BASE_URL = https://your-push-server.example.com
```

### Common Make targets

```bash
make build
make install
make uninstall
make start
make stop
make restart
make reinstall
make logs
make status
make install-hooks
make uninstall-hooks
```

### push-server in Docker

One-click deploy (recommended, secrets in env file):

```bash
make push-server-env-init
# run interactive wizard (it asks and writes ops/deploy/push-server.env)
make push-server-deploy
make push-server-status
```

`ops/deploy/push-server.env` is gitignored and keeps APNs secrets out of command history.

Additional Docker targets:

```bash
make push-server-docker-fmt
make push-server-docker-test
make push-server-docker-build
make push-server-docker-image
make push-server-docker-run
```

`push-server` secret env vars (put in `ops/deploy/push-server.env`):

```bash
APNS_KEY_BASE64=...
APNS_KEY_ID=...
APNS_TEAM_ID=...
APNS_BUNDLE_ID=...
PUSH_SERVER_COMPAT_NOTIFY_TOKEN=...
```

Metrics endpoints:

```bash
GET /metrics
GET /metrics.json
```

Observability templates:

- `ops/observability/prometheus-alert-rules.yml`
- `ops/observability/grafana-dashboard-reattach-slo.json`

## Security Notes

- Reattach enables remote command execution; deploy with care.
- `reattachd` defaults to `127.0.0.1:8787`.
- All control APIs require bearer token credentials.
- Prefer HTTPS or private network transport.
- Rotate/revoke unused devices with:

```bash
reattachd devices list
reattachd devices revoke <device-id>
```

## Breaking Changes Reference

- `docs/breaking-changes-flag-day-2026.md`
- `plans/phase0/breaking-changes-lock.md`

## License

MIT
