use std::{path::Path, time::Duration};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    time::{sleep, Instant},
};

use crate::{
    config::{ensure_private_dir, AgentConfig},
    paths::AgentPaths,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BellEvent {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_target: Option<String>,
    pub event_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BellIngestRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_target: Option<String>,
    pub event_ts: DateTime<Utc>,
}

impl From<BellEvent> for BellIngestRequest {
    fn from(value: BellEvent) -> Self {
        Self {
            pane_target: value.pane_target,
            event_ts: value.event_ts,
        }
    }
}

pub async fn run(paths: &AgentPaths, config: AgentConfig) -> Result<()> {
    ensure_private_dir(&paths.runtime_dir)?;
    if paths.socket_path.exists() {
        std::fs::remove_file(&paths.socket_path).with_context(|| {
            format!("failed to remove stale socket {}", paths.socket_path.display())
        })?;
    }

    let listener = UnixListener::bind(&paths.socket_path)
        .with_context(|| format!("failed to bind socket {}", paths.socket_path.display()))?;
    tracing::info!(socket = %paths.socket_path.display(), "host-agent daemon started");

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
        .context("failed to initialize HTTP client")?;

    loop {
        let (stream, _) = listener.accept().await.context("socket accept failed")?;
        let client = client.clone();
        let config = config.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_connection(stream, client, config).await {
                tracing::warn!(error = %err, "failed to handle bell event");
            }
        });
    }
}

pub async fn emit(paths: &AgentPaths, pane_target: Option<String>) -> Result<bool> {
    let event = BellEvent {
        pane_target: normalize_pane_target(pane_target),
        event_ts: Utc::now(),
    };

    let mut stream = match UnixStream::connect(&paths.socket_path).await {
        Ok(stream) => stream,
        Err(err) => {
            tracing::warn!(
                socket = %paths.socket_path.display(),
                error = %err,
                "host-agent daemon is not reachable; bell event dropped"
            );
            return Ok(false);
        }
    };

    let payload = serde_json::to_vec(&event).context("failed to encode bell event")?;
    stream
        .write_all(&payload)
        .await
        .context("failed to write to daemon socket")?;
    stream
        .shutdown()
        .await
        .context("failed to close daemon socket")?;
    Ok(true)
}

pub async fn is_socket_connectable(socket_path: &Path) -> bool {
    UnixStream::connect(socket_path).await.is_ok()
}

pub async fn wait_for_socket_connectable(socket_path: &Path, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if is_socket_connectable(socket_path).await {
            return true;
        }
        sleep(Duration::from_millis(200)).await;
    }
    false
}

async fn handle_connection(
    mut stream: UnixStream,
    client: reqwest::Client,
    config: AgentConfig,
) -> Result<()> {
    let mut buf = Vec::new();
    stream
        .read_to_end(&mut buf)
        .await
        .context("failed reading socket payload")?;

    if buf.is_empty() {
        return Ok(());
    }

    let payload = trim_ascii_whitespace(&buf);
    if payload.is_empty() {
        return Ok(());
    }

    let event: BellEvent = serde_json::from_slice(payload).context("invalid bell event JSON")?;
    if let Err(err) = send_event(&client, &config, event.clone()).await {
        tracing::warn!(
            error = %err,
            pane_target = ?event.pane_target,
            "failed to send bell event to push-server (best-effort drop)"
        );
    }
    Ok(())
}

async fn send_event(client: &reqwest::Client, config: &AgentConfig, event: BellEvent) -> Result<()> {
    let request_body: BellIngestRequest = event.into();

    let response = client
        .post(&config.ingest_url)
        .bearer_auth(&config.ingest_token)
        .json(&request_body)
        .send()
        .await
        .with_context(|| format!("request to {} failed", config.ingest_url))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "<unable to read body>".to_string());
        anyhow::bail!("HTTP {} {}", status, body);
    }

    tracing::info!(pane_target = ?request_body.pane_target, "bell event sent");
    Ok(())
}

fn trim_ascii_whitespace(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|b| !b.is_ascii_whitespace())
        .map(|idx| idx + 1)
        .unwrap_or(start);
    &bytes[start..end]
}

fn normalize_pane_target(value: Option<String>) -> Option<String> {
    value.and_then(|raw| {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn bell_ingest_payload_serialization_contains_expected_fields() {
        let event = BellEvent {
            pane_target: Some("dev:0.0".to_string()),
            event_ts: Utc::now(),
        };
        let payload: BellIngestRequest = event.into();
        let value: Value = serde_json::to_value(payload).expect("serialize");

        assert_eq!(value.get("pane_target").and_then(Value::as_str), Some("dev:0.0"));
        assert!(value.get("event_ts").is_some());
    }

    #[test]
    fn trim_ascii_whitespace_handles_empty_payload() {
        let raw = b" \n\t ";
        assert_eq!(trim_ascii_whitespace(raw), b"");
    }
}
