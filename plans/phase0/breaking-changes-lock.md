# Reattach Breaking Changes Lock (Phase 0)

## Purpose
- Freeze and track all approved breaking changes for the blueprint migration.
- Prevent scope drift before Flag Day cutover.

## Status
- Baseline frozen by `TASK.md`.
- Any additions require explicit approval and this file update.

## Locked Breaking Changes
1. QR onboarding removal
- Remove setup-token QR registration as a supported onboarding path.
- Impacted areas:
- `reattachd` `/register` and `setup` CLI (future phases)
- iOS QR scanner onboarding UI/flow
- setup docs that instruct QR registration

2. Cloudflare Access Service Token compatibility removal
- Remove app-side service-token-specific UX and header compatibility path.
- Impacted areas:
- iOS server settings fields and request headers for service token
- Cloudflare service-token specific guidance in app flow

3. Open mode removal
- All control APIs must require bearer token, no anonymous mode.
- Impacted areas:
- `reattachd` auth middleware behavior
- operator onboarding expectations

## Explicitly Preserved (Non-breaking within this migration)
1. tmux control API endpoints (`sessions`/`panes` routes) remain for iOS control use.
2. `notify/hooks` compatibility path remains available.
3. Notification routing key remains `deviceId + paneTarget`.

## Governance
- Owner: `TBD Owner`
- Review cadence: once per week until Flag Day.
- Change process:
1. Raise proposal in issue/PR.
2. Evaluate compatibility and rollback impact.
3. Update this file only after approval.

