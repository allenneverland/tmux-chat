# Phase 8: Flag Day 48h Observation Checklist

## Scope

Observation window after Flag Day rollout (`T+0h` to `T+48h`).

## Owners

- Observation lead: `TBD`
- On-call backend: `TBD`
- On-call iOS: `TBD`

## Checkpoints

### T+0h (immediately after rollout)

- [ ] `events_bell_total` increases after a manual tmux bell test.
- [ ] `events_agent_total` increases after a `tmux-chatd notify` test.
- [ ] `apns_sent_total` increases.
- [ ] p95 `event_to_apns_latency_ms` is below 10000 ms.
- [ ] iOS notification tap routes to expected pane (`deviceId + paneTarget`).

### T+1h

- [ ] No sustained API `5xx` anomaly.
- [ ] `route_success_total / notification_tap_total >= 0.99` for the interval.
- [ ] No unexpected surge in `route_fallback_total`.

### T+24h

- [ ] Invalid token cleanup ratio is healthy:
  - `increase(invalid_token_removed_total[24h]) / max(increase(invalid_token_detected_total[24h]), 1) >= 0.99`
- [ ] No repeated alert flapping from `EventToApnsLatencyP95High`.
- [ ] No unresolved Sev-2+ incidents.

### T+48h (exit gate)

- [ ] SLO signals remain within target.
- [ ] No open migration-related Sev-1/Sev-2 incidents.
- [ ] Final rollout summary published (metrics snapshot + issue summary).

## Alert References

- `EventToApnsLatencyP95High`
- `RouteSuccessRateLow`
- `InvalidTokenCleanupRateLow`

Defined in: `ops/observability/prometheus-alert-rules.yml`

## Evidence to attach

- Metrics screenshots or query outputs for each checkpoint.
- Example notification routing proof (success and fallback handling).
- Incident links (if any).
