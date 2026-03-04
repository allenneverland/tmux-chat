# Reattach Rollout / Rollback Runbook (Flag Day)

## Scope

This runbook covers Flag Day execution for the blueprint migration baseline.

## Preconditions

- [ ] Phase 8 docs merged.
- [ ] Release artifacts built from approved commit SHA.
- [ ] Push-server deployment has valid APNs credentials.
- [ ] On-call coverage confirmed for full window.

## Rollout Procedure

1. Announce maintenance window start.
2. Verify commit SHA and deployed artifact match.
3. Deploy in this order:
- `push-server`
- `reattachd`
- host packaging updates (`host-agent` release availability)
- iOS validation build verification
4. Run smoke checks:
- `GET /sessions` returns `401` without bearer token.
- `GET /sessions` succeeds with valid token.
- `POST /notify` (via `reattachd notify`) is accepted and forwarded.
- tmux bell event from host-agent reaches push-server ingest.
5. Verify metrics move:
- `events_bell_total` increments.
- `events_agent_total` increments.
- `apns_sent_total` increments (or expected mock behavior in staging).
6. Announce rollout complete; start 48h observation checklist.

## Rollback Triggers

- Invalid auth behavior (accepting invalid token or rejecting valid token).
- Sustained `5xx` error rate above agreed threshold for 15 minutes.
- Notification delivery pipeline broken with no forward fix in 30 minutes.
- Any Sev-1 user-impacting issue.

## Rollback Procedure

1. Announce rollback start; freeze all further deploys.
2. Revert to last known-good release artifact/commit.
3. Restore previous service definitions/config values.
4. Run rollback smoke checks:
- tmux control endpoints healthy.
- auth behavior matches pre-cutover baseline.
- `reattachd notify` compatibility path works.
5. Announce rollback completion with incident summary.

## Post-Rollout Validation

- [ ] API availability healthy.
- [ ] Auth middleware behavior validated.
- [ ] iOS build/check remains green.
- [ ] SLO dashboard/alerts accessible.
- [ ] 48h observation owner assigned.

## Postmortem Requirements (if rollback happened)

- UTC timeline.
- Trigger and root cause.
- Corrective actions with owner and due date.
