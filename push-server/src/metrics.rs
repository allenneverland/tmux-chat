use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Default)]
pub struct Metrics {
    pub events_bell_total: AtomicU64,
    pub events_agent_total: AtomicU64,
    pub apns_sent_total: AtomicU64,
    pub apns_failed_total: AtomicU64,
    pub invalid_token_removed_total: AtomicU64,
    pub event_to_apns_latency_ms_total: AtomicU64,
    pub event_to_apns_latency_samples: AtomicU64,
}

#[derive(Debug, Serialize)]
pub struct MetricsSnapshot {
    pub events_bell_total: u64,
    pub events_agent_total: u64,
    pub apns_sent_total: u64,
    pub apns_failed_total: u64,
    pub invalid_token_removed_total: u64,
    pub event_to_apns_latency_ms_total: u64,
    pub event_to_apns_latency_samples: u64,
}

impl Metrics {
    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            events_bell_total: self.events_bell_total.load(Ordering::Relaxed),
            events_agent_total: self.events_agent_total.load(Ordering::Relaxed),
            apns_sent_total: self.apns_sent_total.load(Ordering::Relaxed),
            apns_failed_total: self.apns_failed_total.load(Ordering::Relaxed),
            invalid_token_removed_total: self.invalid_token_removed_total.load(Ordering::Relaxed),
            event_to_apns_latency_ms_total: self.event_to_apns_latency_ms_total.load(Ordering::Relaxed),
            event_to_apns_latency_samples: self.event_to_apns_latency_samples.load(Ordering::Relaxed),
        }
    }

    pub fn observe_latency_ms(&self, ms: u64) {
        self.event_to_apns_latency_ms_total
            .fetch_add(ms, Ordering::Relaxed);
        self.event_to_apns_latency_samples
            .fetch_add(1, Ordering::Relaxed);
    }
}
