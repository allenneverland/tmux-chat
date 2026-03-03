# Reattach Observability (Phase 7)

This directory contains production-ready observability artifacts for Reattach Phase 7.

## Metrics endpoints

- `GET /metrics` (Prometheus exposition format)
- `GET /metrics.json` (debug JSON snapshot)

## Core SLO metrics

- `event_to_apns_latency_ms` (histogram)
- `notification_tap_total`
- `route_success_total`
- `route_fallback_total`
- `invalid_token_detected_total`
- `invalid_token_removed_total`

## Prometheus scrape config example

```yaml
scrape_configs:
  - job_name: reattach-push-server
    metrics_path: /metrics
    static_configs:
      - targets: ["push-server:8790"]
```

## Alert rules

Use [`prometheus-alert-rules.yml`](./prometheus-alert-rules.yml) and load it via Prometheus `rule_files`.

## Grafana dashboard

Import [`grafana-dashboard-reattach-slo.json`](./grafana-dashboard-reattach-slo.json) into Grafana.

## Suggested SLO alert routing

- `EventToApnsLatencyP95High`: page on-call.
- `RouteSuccessRateLow`: page on-call.
- `InvalidTokenCleanupRateLow`: notify platform channel first, escalate if sustained.
