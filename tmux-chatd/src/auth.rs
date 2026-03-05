use chrono::{DateTime, Utc};
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;
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
    store_stamp: RwLock<StoreStamp>,
    data_path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct StoreStamp {
    modified: Option<SystemTime>,
    len: u64,
}

impl AuthService {
    pub async fn new(data_dir: PathBuf) -> Result<Self, std::io::Error> {
        std::fs::create_dir_all(&data_dir)?;
        let data_path = data_dir.join("auth.json");

        let (store, store_stamp) = load_store_and_stamp(&data_path)?;

        Ok(Self {
            store: RwLock::new(store),
            store_stamp: RwLock::new(store_stamp),
            data_path,
        })
    }

    async fn save(&self) -> Result<(), std::io::Error> {
        let store = self.store.read().await;
        let content = serde_json::to_string_pretty(&*store)?;
        std::fs::write(&self.data_path, content)?;
        let stamp = file_stamp(&self.data_path);
        *self.store_stamp.write().await = stamp;
        Ok(())
    }

    async fn refresh_from_disk_if_changed(&self) -> Result<(), std::io::Error> {
        let latest_stamp = file_stamp(&self.data_path);
        let current_stamp = *self.store_stamp.read().await;

        if latest_stamp == current_stamp {
            return Ok(());
        }

        let (latest_store, confirmed_stamp) = load_store_and_stamp(&self.data_path)?;
        *self.store.write().await = latest_store;
        *self.store_stamp.write().await = confirmed_stamp;
        Ok(())
    }

    async fn force_reload_from_disk(&self) -> Result<(), std::io::Error> {
        let (latest_store, confirmed_stamp) = load_store_and_stamp(&self.data_path)?;
        *self.store.write().await = latest_store;
        *self.store_stamp.write().await = confirmed_stamp;
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
        let _ = self.refresh_from_disk_if_changed().await;
        if let Some(found) = {
            let store = self.store.read().await;
            store.devices.iter().find(|d| d.token == token).cloned()
        } {
            return Some(found);
        }

        // Fallback: force a hard reload in case filesystem timestamp granularity
        // prevented change detection for back-to-back writes.
        let _ = self.force_reload_from_disk().await;
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
        let _ = self.refresh_from_disk_if_changed().await;
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
        let _ = self.refresh_from_disk_if_changed().await;
        let store = self.store.read().await;
        !store.devices.is_empty()
    }
}

fn load_store_and_stamp(path: &Path) -> Result<(AuthStore, StoreStamp), std::io::Error> {
    if !path.exists() {
        return Ok((AuthStore::default(), StoreStamp::default()));
    }

    let content = std::fs::read_to_string(path)?;
    let store = serde_json::from_str(&content).unwrap_or_default();
    Ok((store, file_stamp(path)))
}

fn file_stamp(path: &Path) -> StoreStamp {
    match std::fs::metadata(path) {
        Ok(meta) => StoreStamp {
            modified: meta.modified().ok(),
            len: meta.len(),
        },
        Err(_) => StoreStamp::default(),
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

    #[tokio::test]
    async fn daemon_view_reflects_external_issue_and_revoke() {
        let data_dir = unique_test_data_dir();
        let daemon = AuthService::new(data_dir.clone()).await.unwrap();
        let cli = AuthService::new(data_dir.clone()).await.unwrap();

        let issued = cli.issue_device("iPhone").await;
        assert!(daemon.validate_device_token(&issued.token).await.is_some());

        assert!(cli.revoke_device(&issued.id).await);
        assert!(daemon.validate_device_token(&issued.token).await.is_none());

        let _ = std::fs::remove_dir_all(data_dir);
    }
}
