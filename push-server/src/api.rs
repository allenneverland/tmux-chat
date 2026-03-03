use std::sync::atomic::Ordering;

use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    Json,
};
use chrono::Utc;

use crate::{
    db::Database,
    error::{AppError, AppResult},
    models::{
        ApnsEvent, CompletePairingRequest, CreateMuteRequest, EventSource, IngestEventRequest,
        IngestEventResponse, RegisterDeviceRequest,
    },
    state::AppState,
};

pub async fn healthz() -> &'static str {
    "ok"
}

pub async fn metrics(State(state): State<AppState>) -> Json<crate::metrics::MetricsSnapshot> {
    Json(state.metrics.snapshot())
}

pub async fn start_pairing(
    State(state): State<AppState>,
    Json(req): Json<crate::models::StartPairingRequest>,
) -> AppResult<Json<crate::models::StartPairingResponse>> {
    let response = state
        .db
        .start_pairing(req, state.config.pairing_ttl_seconds)?;
    Ok(Json(response))
}

pub async fn complete_pairing(
    State(state): State<AppState>,
    Json(req): Json<CompletePairingRequest>,
) -> AppResult<Json<crate::models::CompletePairingResponse>> {
    let response = state.db.complete_pairing(req, &state.config.ingest_url())?;
    Ok(Json(response))
}

pub async fn register_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<RegisterDeviceRequest>,
) -> AppResult<Json<crate::models::RegisterDeviceResponse>> {
    let bearer = bearer_token(&headers)?;
    let response = state.db.register_device(&bearer, req)?;
    Ok(Json(response))
}

pub async fn ingest_bell(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<IngestEventRequest>,
) -> AppResult<Json<IngestEventResponse>> {
    ingest_event(&state, &headers, req, EventSource::Bell).await
}

pub async fn ingest_agent(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<IngestEventRequest>,
) -> AppResult<Json<IngestEventResponse>> {
    ingest_event(&state, &headers, req, EventSource::Agent).await
}

pub async fn create_mute(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateMuteRequest>,
) -> AppResult<Json<crate::models::CreateMuteResponse>> {
    let token = authorize_device_api(&state.db, &headers)?;
    let response = state.db.create_mute(&token.subject_id, req)?;
    Ok(Json(response))
}

pub async fn delete_mute(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(mute_id): Path<String>,
) -> AppResult<StatusCode> {
    let token = authorize_device_api(&state.db, &headers)?;
    let deleted = state.db.delete_mute(&token.subject_id, &mute_id)?;
    if deleted {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::NotFound("mute rule not found".to_string()))
    }
}

async fn ingest_event(
    state: &AppState,
    headers: &HeaderMap,
    req: IngestEventRequest,
    source: EventSource,
) -> AppResult<Json<IngestEventResponse>> {
    let raw_bearer = bearer_token(headers)?;

    let allowed_scopes = if source == EventSource::Bell {
        vec![Database::token_scope_host_ingest()]
    } else {
        vec![
            Database::token_scope_host_ingest(),
            Database::token_scope_compat_notify(),
        ]
    };

    let token = state.db.validate_token(&raw_bearer, &allowed_scopes)?;
    if source == EventSource::Bell {
        state
            .metrics
            .events_bell_total
            .fetch_add(1, Ordering::Relaxed);
    } else {
        state
            .metrics
            .events_agent_total
            .fetch_add(1, Ordering::Relaxed);
    }

    let event_ts = req.event_ts.unwrap_or_else(Utc::now);
    let title = req.title.unwrap_or_else(|| {
        if source == EventSource::Bell {
            "tmux bell".to_string()
        } else {
            "Coding Agent".to_string()
        }
    });
    let body = req.body.unwrap_or_else(|| {
        if source == EventSource::Bell {
            "Bell detected".to_string()
        } else {
            "Waiting for input".to_string()
        }
    });

    let event = ApnsEvent {
        source,
        title,
        body,
        pane_target: req.pane_target,
        event_ts,
    };

    let candidates = if token.scope == Database::token_scope_host_ingest() {
        state.db.list_devices_for_host(&token.subject_id)?
    } else {
        state.db.list_all_devices()?
    };

    let mut muted = 0u64;
    let mut deliverable = Vec::new();
    for device in candidates {
        let is_muted = state
            .db
            .is_muted(&device.device_id, source, event.pane_target.as_deref())?;
        if is_muted {
            muted += 1;
        } else {
            deliverable.push(device);
        }
    }

    let attempted = deliverable.len() as u64;
    let mut delivered = 0u64;
    let mut failed = 0u64;

    if let Some(apns) = &state.apns {
        let dispatch = apns.send_to_devices(&deliverable, &event).await;
        delivered = dispatch.sent;
        failed = dispatch.failed;

        if !dispatch.invalid_device_ids.is_empty() {
            let removed = state.db.revoke_devices(&dispatch.invalid_device_ids)?;
            state
                .metrics
                .invalid_token_removed_total
                .fetch_add(removed, Ordering::Relaxed);
        }
    } else {
        tracing::warn!("APNs not configured; dropping event");
        failed = attempted;
    }

    state
        .metrics
        .apns_sent_total
        .fetch_add(delivered, Ordering::Relaxed);
    state
        .metrics
        .apns_failed_total
        .fetch_add(failed, Ordering::Relaxed);

    if Utc::now() >= event.event_ts {
        let latency_ms = (Utc::now() - event.event_ts).num_milliseconds().max(0) as u64;
        state.metrics.observe_latency_ms(latency_ms);
    }

    Ok(Json(IngestEventResponse {
        attempted,
        muted,
        delivered,
        failed,
    }))
}

fn authorize_device_api(db: &Database, headers: &HeaderMap) -> AppResult<crate::models::TokenRecord> {
    let bearer = bearer_token(headers)?;
    let token = db.validate_token(&bearer, &[Database::token_scope_device_api()])?;
    if token.consumed_at.is_some() {
        return Err(AppError::unauthorized("device token already consumed"));
    }
    Ok(token)
}

fn bearer_token(headers: &HeaderMap) -> AppResult<String> {
    let value = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| AppError::unauthorized("missing Authorization header"))?;

    let token = value
        .strip_prefix("Bearer ")
        .ok_or_else(|| AppError::unauthorized("invalid Authorization scheme"))?
        .trim();

    if token.is_empty() {
        return Err(AppError::unauthorized("empty bearer token"));
    }

    Ok(token.to_string())
}
