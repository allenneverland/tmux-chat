use std::time::Duration;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
struct CompletePairingRequest<'a> {
    pairing_token: &'a str,
    host_name: &'a str,
    platform: &'a str,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CompletePairingResponse {
    pub host_id: String,
    pub ingest_token: String,
    pub ingest_url: String,
}

#[derive(Debug, Deserialize)]
struct ErrorResponse {
    error: String,
}

pub async fn complete_pairing(
    push_server_base_url: &str,
    pairing_token: &str,
    host_name: &str,
    platform: &str,
) -> Result<CompletePairingResponse> {
    let url = format!(
        "{}/v1/pairings/complete",
        push_server_base_url.trim_end_matches('/')
    );

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .context("failed to initialize HTTP client")?;

    let response = client
        .post(&url)
        .json(&CompletePairingRequest {
            pairing_token,
            host_name,
            platform,
        })
        .send()
        .await
        .with_context(|| format!("pairing request failed: {}", url))?;

    if !response.status().is_success() {
        let status = response.status();
        let raw_body = response.text().await.unwrap_or_default();
        let message = serde_json::from_str::<ErrorResponse>(&raw_body)
            .map(|e| e.error)
            .unwrap_or(raw_body);
        anyhow::bail!("pairing failed (HTTP {}): {}", status, message);
    }

    response
        .json::<CompletePairingResponse>()
        .await
        .context("failed to parse pairing response")
}
