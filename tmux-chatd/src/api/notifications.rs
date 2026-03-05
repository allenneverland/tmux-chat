use axum::{extract::State, http::StatusCode, Json};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Clone)]
pub struct NotifyForwarder {
    client: reqwest::Client,
    push_server_base_url: String,
    compat_notify_token: String,
}

impl NotifyForwarder {
    pub fn new(push_server_base_url: String, compat_notify_token: String) -> Self {
        Self {
            client: reqwest::Client::new(),
            push_server_base_url,
            compat_notify_token,
        }
    }

    async fn forward(&self, payload: &SendNotificationRequest) -> Result<(), reqwest::Error> {
        let url = format!(
            "{}/v1/events/agent",
            self.push_server_base_url.trim_end_matches('/')
        );

        let body = ForwardAgentEventRequest {
            pane_target: payload.pane_target.clone(),
            title: payload.title.clone(),
            body: payload.body.clone(),
            event_ts: Utc::now(),
        };

        self.client
            .post(url)
            .header(
                "Authorization",
                format!("Bearer {}", self.compat_notify_token),
            )
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?
            .error_for_status()?;

        Ok(())
    }
}

pub type SharedNotifyForwarder = Arc<NotifyForwarder>;

#[derive(Deserialize)]
pub struct SendNotificationRequest {
    pub title: String,
    pub body: String,
    pub pane_target: Option<String>,
}

#[derive(Serialize)]
struct ForwardAgentEventRequest {
    pane_target: Option<String>,
    title: String,
    body: String,
    event_ts: chrono::DateTime<Utc>,
}

pub async fn send_notification(
    State(forwarder): State<SharedNotifyForwarder>,
    Json(payload): Json<SendNotificationRequest>,
) -> StatusCode {
    match forwarder.forward(&payload).await {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::error!("Failed to forward notification to push-server: {}", e);
            StatusCode::BAD_GATEWAY
        }
    }
}
