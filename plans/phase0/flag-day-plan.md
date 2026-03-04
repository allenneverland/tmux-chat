# TmuxChat Flag Day Plan (Phase 0 -> Phase 8)

## Document Control

| Field | Value |
|---|---|
| Status | Draft (Ready for scheduling) |
| Owner | TBD |
| Target Date | TBD |
| Last Updated | 2026-03-03 |
| Scope | Blueprint cutover + 48h observation |

## Objective

Execute a single-cutover migration to the SSH onboarding + host-agent + push-server baseline, while preserving tmux control APIs and coding-agent notify compatibility.

## Entry Criteria

- [ ] `plans/phase0/rollout-rollback-runbook.md` approved.
- [ ] `plans/phase0/breaking-changes-lock.md` approved.
- [ ] `docs/breaking-changes-flag-day-2026.md` published.
- [ ] CI green for `tmux-chatd`, `host-agent`, `push-server`, iOS build.
- [ ] SLO dashboard and alert rules reachable by on-call.
- [ ] Rollback rehearsal completed within last 7 days.

## Cutover Window (TBD)

- Planned start: `TBD`
- Planned end: `TBD`
- Change freeze starts: `T-24h`

## Roles and Responsibilities

- Incident commander: `TBD`
- Release operator: `TBD`
- iOS validation owner: `TBD`
- Backend validation owner: `TBD`
- Observer/scribe: `TBD`

## Timeline

1. `T-14d`: finalize docs + release notes + migration announcement.
2. `T-7d`: run rollback rehearsal and capture timings.
3. `T-2d`: preflight checks (artifacts, env vars, metrics, alerts).
4. `T-0`: execute rollout runbook.
5. `T+0h to T+48h`: heightened observation using `plans/phase8/observation-48h-checklist.md`.

## Go / No-Go Checklist

- [ ] All required CI checks green.
- [ ] Approved release artifact SHA recorded.
- [ ] APNs credentials loaded on push-server.
- [ ] `PUSH_SERVER_BASE_URL` and `PUSH_SERVER_COMPAT_NOTIFY_TOKEN` verified.
- [ ] On-call acknowledgements received.
- [ ] Communication templates prepared.

## Communication Plan

- Start notice: at cutover start (`T-0`).
- Midpoint notice: after smoke checks pass.
- End notice: after rollout completion + observation handoff.
- Incident channel: `TBD`
- Public status update owner: `TBD`

## Exit Criteria

- [ ] Rollout smoke checks passed.
- [ ] No Sev-1/Sev-2 unresolved incidents.
- [ ] 48h observation checklist completed.
- [ ] Final summary posted with metrics snapshot.
