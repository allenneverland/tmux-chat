# Reattach Flag Day Plan (Phase 0)

## Document Control
| Field | Value |
|---|---|
| Status | Draft (Execution Baseline) |
| Owner | TBD Owner |
| Target Date | TBD |
| Last Updated | 2026-03-03 |
| Scope | Phase 0/1 preparation for blueprint migration |

## Objective
- Execute a single-cutover (Flag Day) migration from current architecture to the blueprint baseline in `TASK.md`.
- Prevent partial rollout states that mix legacy onboarding/auth assumptions with new pairing/agent flow.

## Entry Criteria
- [ ] `plans/phase0/rollout-rollback-runbook.md` approved.
- [ ] `plans/phase0/breaking-changes-lock.md` approved.
- [ ] Phase 1 CI green on default branch.
- [ ] Release build for `reattachd` confirmed with workspace layout.
- [ ] Internal announcement draft prepared.

## Cutover Window (TBD)
- Planned start: `TBD`
- Planned end: `TBD`
- Change freeze: start minus 24h

## Roles and Responsibilities
- Incident commander: `TBD Owner`
- Release operator: `TBD`
- iOS validation owner: `TBD`
- Backend validation owner: `TBD`

## Execution Timeline
1. `T-14d` finalize runbook + rollback rehearsal.
2. `T-7d` lock breaking changes and freeze incompatible PRs.
3. `T-2d` preflight verification (CI, release artifact, docs readiness).
4. `T-0` execute rollout runbook.
5. `T+48h` heightened monitoring and issue triage.

## Go / No-Go Checklist
- [ ] CI required checks all green.
- [ ] Rollout steps validated in rehearsal.
- [ ] Rollback path tested and documented.
- [ ] SLO dashboard/alerts reachable by on-call.
- [ ] Stakeholder notifications sent.

## Communication Plan
- Start notice: at cutover start.
- Midpoint update: when control plane + notification path pass smoke tests.
- End notice: once post-checklist is complete.
- Incident channel: `TBD`.

