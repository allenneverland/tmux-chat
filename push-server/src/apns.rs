use a2::{
    Client, ClientConfig, DefaultNotificationBuilder, Endpoint, NotificationBuilder,
    NotificationOptions,
};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::Value;
use std::io::Cursor;

use crate::config::ApnsConfig;
use crate::error::{AppError, AppResult};
use crate::models::{ApnsEvent, DeviceRecord, DispatchResult};

pub struct ApnsService {
    sandbox_client: Client,
    production_client: Client,
    bundle_id: String,
}

impl ApnsService {
    pub fn new(config: &ApnsConfig) -> AppResult<Self> {
        let key_bytes = STANDARD
            .decode(&config.key_base64)
            .map_err(|e| AppError::internal(format!("invalid APNS_KEY_BASE64: {}", e)))?;
        let key = String::from_utf8(key_bytes)
            .map_err(|e| AppError::internal(format!("invalid APNS key UTF-8: {}", e)))?;

        let sandbox_client = create_client(&key, &config.key_id, &config.team_id, true)?;
        let production_client = create_client(&key, &config.key_id, &config.team_id, false)?;

        Ok(Self {
            sandbox_client,
            production_client,
            bundle_id: config.bundle_id.clone(),
        })
    }

    pub async fn send_to_devices(
        &self,
        devices: &[DeviceRecord],
        event: &ApnsEvent,
    ) -> DispatchResult {
        if devices.is_empty() {
            return DispatchResult {
                sent: 0,
                failed: 0,
                invalid_device_ids: Vec::new(),
            };
        }

        let options = NotificationOptions {
            apns_topic: Some(&self.bundle_id),
            ..Default::default()
        };

        let mut sent = 0u64;
        let mut failed = 0u64;
        let mut invalid_device_ids = Vec::new();

        for device in devices {
            let title = build_title(&device.server_name, &event.title);
            let builder = DefaultNotificationBuilder::new()
                .set_title(&title)
                .set_body(&event.body)
                .set_sound("default");

            let mut payload = builder.build(&device.apns_token, options.clone());
            payload
                .data
                .insert("deviceId".to_string(), Value::String(device.device_id.clone()));
            if let Some(target) = &event.pane_target {
                payload
                    .data
                    .insert("paneTarget".to_string(), Value::String(target.clone()));
            }
            payload
                .data
                .insert("title".to_string(), Value::String(event.title.clone()));
            payload
                .data
                .insert("body".to_string(), Value::String(event.body.clone()));
            payload.data.insert(
                "eventTs".to_string(),
                Value::String(event.event_ts.to_rfc3339()),
            );
            payload.data.insert(
                "source".to_string(),
                Value::String(event.source.as_str().to_string()),
            );

            let client = if device.sandbox {
                &self.sandbox_client
            } else {
                &self.production_client
            };

            match client.send(payload).await {
                Ok(_) => {
                    sent += 1;
                }
                Err(a2::Error::ResponseError(ref response)) => {
                    if let Some(ref error_body) = response.error {
                        if error_body.reason == a2::ErrorReason::BadDeviceToken {
                            failed += 1;
                            invalid_device_ids.push(device.id.clone());
                            continue;
                        }
                    }
                    failed += 1;
                    tracing::error!(
                        token = %device.apns_token,
                        "APNs response error: {:?}",
                        response
                    );
                }
                Err(e) => {
                    failed += 1;
                    tracing::error!(token = %device.apns_token, "APNs send error: {:?}", e);
                }
            }
        }

        DispatchResult {
            sent,
            failed,
            invalid_device_ids,
        }
    }
}

fn create_client(key: &str, key_id: &str, team_id: &str, sandbox: bool) -> AppResult<Client> {
    let mut cursor = Cursor::new(key.as_bytes());
    let endpoint = if sandbox {
        Endpoint::Sandbox
    } else {
        Endpoint::Production
    };
    let client_config = ClientConfig::new(endpoint);
    Client::token(&mut cursor, key_id, team_id, client_config)
        .map_err(|e| AppError::internal(format!("failed to initialize APNs client: {}", e)))
}

fn build_title(server_name: &str, title: &str) -> String {
    if server_name.trim().is_empty() {
        return title.to_string();
    }

    let full = format!("{}: {}", server_name, title);
    const MAX_LEN: usize = 40;
    if full.chars().count() <= MAX_LEN {
        return full;
    }

    let prefix = format!("{}: ...", server_name);
    let remaining = MAX_LEN.saturating_sub(prefix.chars().count());
    let chars: Vec<char> = title.chars().collect();
    let skip = chars.len().saturating_sub(remaining);
    format!("{}{}", prefix, chars[skip..].iter().collect::<String>())
}
