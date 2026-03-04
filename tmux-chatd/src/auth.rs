use chrono::{DateTime, Utc};
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub token: String,
    pub registered_at: DateTime<Utc>,
    pub last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AuthStore {
    pub devices: Vec<Device>,
}

pub struct AuthService {
    store: RwLock<AuthStore>,
    data_path: PathBuf,
}

impl AuthService {
    pub async fn new(data_dir: PathBuf) -> Result<Self, std::io::Error> {
        std::fs::create_dir_all(&data_dir)?;
        let data_path = data_dir.join("auth.json");

        let store = if data_path.exists() {
            let content = std::fs::read_to_string(&data_path)?;
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            AuthStore::default()
        };

        Ok(Self {
            store: RwLock::new(store),
            data_path,
        })
    }

    async fn save(&self) -> Result<(), std::io::Error> {
        let store = self.store.read().await;
        let content = serde_json::to_string_pretty(&*store)?;
        std::fs::write(&self.data_path, content)?;
        Ok(())
    }

    pub async fn issue_device(&self, device_name: &str) -> Device {
        let device = Device {
            id: uuid::Uuid::new_v4().to_string(),
            name: device_name.to_string(),
            token: generate_token(),
            registered_at: Utc::now(),
            last_seen_at: None,
        };

        {
            let mut store = self.store.write().await;
            store.devices.push(device.clone());
        }

        let _ = self.save().await;
        device
    }

    pub async fn validate_device_token(&self, token: &str) -> Option<Device> {
        let store = self.store.read().await;
        store.devices.iter().find(|d| d.token == token).cloned()
    }

    pub async fn update_last_seen(&self, device_id: &str) {
        {
            let mut store = self.store.write().await;
            if let Some(device) = store.devices.iter_mut().find(|d| d.id == device_id) {
                device.last_seen_at = Some(Utc::now());
            }
        }
        let _ = self.save().await;
    }

    pub async fn list_devices(&self) -> Vec<Device> {
        let store = self.store.read().await;
        store.devices.clone()
    }

    pub async fn revoke_device(&self, device_id: &str) -> bool {
        let removed = {
            let mut store = self.store.write().await;
            let len_before = store.devices.len();
            store.devices.retain(|d| d.id != device_id);
            store.devices.len() < len_before
        };

        if removed {
            let _ = self.save().await;
        }
        removed
    }

    pub async fn has_devices(&self) -> bool {
        let store = self.store.read().await;
        !store.devices.is_empty()
    }
}

fn generate_token() -> String {
    let mut rng = rand::thread_rng();
    let bytes: [u8; 32] = rng.gen();
    base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, bytes)
}

pub type SharedAuthService = Arc<AuthService>;

#[cfg(test)]
mod tests {
    use super::*;

    fn unique_test_data_dir() -> PathBuf {
        std::env::temp_dir().join(format!("tmux-chatd-auth-test-{}", uuid::Uuid::new_v4()))
    }

    #[tokio::test]
    async fn issue_device_creates_unique_records() {
        let data_dir = unique_test_data_dir();
        let auth = AuthService::new(data_dir.clone()).await.unwrap();

        let first = auth.issue_device("iPhone").await;
        let second = auth.issue_device("iPhone").await;

        assert_eq!(first.name, "iPhone");
        assert_ne!(first.id, second.id);
        assert_ne!(first.token, second.token);

        let devices = auth.list_devices().await;
        assert_eq!(devices.len(), 2);

        assert!(auth.validate_device_token(&first.token).await.is_some());
        assert!(auth.validate_device_token(&second.token).await.is_some());

        let _ = std::fs::remove_dir_all(data_dir);
    }

    #[tokio::test]
    async fn revoke_device_invalidates_token() {
        let data_dir = unique_test_data_dir();
        let auth = AuthService::new(data_dir.clone()).await.unwrap();

        let device = auth.issue_device("iPad").await;
        assert!(auth.validate_device_token(&device.token).await.is_some());

        assert!(auth.revoke_device(&device.id).await);
        assert!(auth.validate_device_token(&device.token).await.is_none());

        let _ = std::fs::remove_dir_all(data_dir);
    }
}
