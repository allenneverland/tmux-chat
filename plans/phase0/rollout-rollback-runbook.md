# Reattach Rollout / Rollback Runbook (Phase 0)

## Scope
- Covers Flag Day execution for blueprint migration prerequisites.
- Focuses on operational sequence and reversal criteria before Phase 2+ feature rollout.

## Preconditions
- [ ] Phase 1 workspace + CI changes merged.
- [ ] Release workflow can still produce `reattachd` artifacts.
- [ ] On-call and owner available for full migration window.

## Rollout Procedure
1. Announce maintenance window start.
2. Confirm default branch required checks are green.
3. Confirm latest deploy/release candidate matches approved commit SHA.
4. Execute deployment in this order:
- Infrastructure/workflow updates
- Host-side service packaging updates
- iOS compatibility verification build
5. Run smoke checks:
- Control API auth gate returns `401` without bearer token.
- Existing tmux control endpoints respond successfully with valid token.
- `reattachd notify` compatibility path still accepts calls.
6. Mark rollout as complete and begin 48-hour observation.

## Rollback Triggers
- Critical auth regression (valid token rejected or invalid token accepted).
- Release artifact mismatch or deployment drift.
- Sustained API error rate above threshold for 15 minutes.
- Any Sev-1 user-impacting issue with no forward fix in 30 minutes.

## Rollback Procedure
1. Announce rollback start and freeze further deploys.
2. Revert to the last known-good release artifact/commit.
3. Re-apply previous service definitions/config if changed.
4. Run rollback smoke checks:
- tmux control endpoints healthy.
- authentication behavior matches pre-cutover baseline.
- notification compatibility path works (`reattachd notify`).
5. Announce rollback completion with incident summary.

## Post-Rollout Validation
- [ ] API availability check passed.
- [ ] Auth middleware behavior validated.
- [ ] iOS compile check green in CI.
- [ ] Release packaging check passed.

## Postmortem Requirements (if rollback occurred)
- Timeline with UTC timestamps.
- Trigger root cause.
- Corrective actions with owner and due date.

