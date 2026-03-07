# tmux-chat Breaking Changes (Flag Day 2026)

## Status

- Announcement date: 2026-03-03
- Planned cutover date: TBD
- Incident commander: TBD
- Release operator: TBD

## Why this change

tmux-chat has moved to the blueprint architecture:

- iOS onboarding is SSH-first.
- Notifications are delivered by `host-agent -> push-server -> APNs`.
- tmux remote control APIs stay available via `tmux-chatd`.

This migration removes legacy setup paths that caused product and operational drift.

## Breaking changes

1. QR onboarding removed
- `tmux-chatd setup --url ...` is no longer supported.
- iOS QR scanner onboarding is removed.

2. Cloudflare Access Service Token compatibility removed
- App-side Service Token credential fields/headers are removed.
- tmux-chat no longer documents Service Token-based app authentication flow.

3. Open mode removed
- Control APIs require bearer token authentication.

## Explicitly preserved

1. tmux control APIs remain unchanged for iOS remote control:
- `GET /sessions`
- `POST /sessions`
- `POST /panes/{target}/input`
- `POST /panes/{target}/key`
- `POST /panes/{target}/escape`
- `GET /panes/{target}/output`
- `DELETE /panes/{target}`

2. Coding-agent compatibility path remains:
- `tmux-chatd notify`
- `tmux-chatd hooks install`

3. Notification routing key remains:
- `deviceId + paneTarget`

## Required migration actions

1. Upgrade host setup docs/process to SSH onboarding.
2. Ensure `push-server` is configured and reachable.
3. Re-run onboarding from iOS app (`Add Server via SSH`) to install/pair `host-agent`.
4. Validate notifications:
- tmux bell event arrives on iOS.
- coding-agent hook notification arrives on iOS.

## Rollout and observation

- Rollout runbook: `plans/phase0/rollout-rollback-runbook.md`
- Flag Day plan: `plans/phase0/flag-day-plan.md`
- 48h observation checklist: `plans/phase8/observation-48h-checklist.md`

## Support

If migration issues occur, include these in your report:

- host OS and architecture
- `tmux-chatd` version
- `host-agent status --json` output
- whether tmux bell hooks are active
- relevant timestamps (UTC)
