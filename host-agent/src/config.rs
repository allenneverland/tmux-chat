use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AgentSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub push_server_base_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub host_id: String,
    pub ingest_url: String,
    pub ingest_token: String,
    pub push_server_base_url: String,
    pub host_name: String,
    pub platform: String,
    pub paired_at: DateTime<Utc>,
}

pub fn load_settings(path: &Path) -> Result<AgentSettings> {
    if !path.exists() {
        return Ok(AgentSettings::default());
    }

    let raw = fs::read_to_string(path)
        .with_context(|| format!("failed to read settings file: {}", path.display()))?;
    let mut settings: AgentSettings = serde_json::from_str(&raw)
        .with_context(|| format!("failed to parse settings file: {}", path.display()))?;
    settings.push_server_base_url = settings
        .push_server_base_url
        .as_deref()
        .and_then(normalized_base_url);
    Ok(settings)
}

pub fn save_settings(path: &Path, settings: &AgentSettings) -> Result<()> {
    let mut normalized = settings.clone();
    normalized.push_server_base_url = normalized
        .push_server_base_url
        .as_deref()
        .and_then(normalized_base_url);
    write_json_private(path, &normalized)
}

pub fn load_agent_config(path: &Path) -> Result<Option<AgentConfig>> {
    if !path.exists() {
        return Ok(None);
    }

    let raw = fs::read_to_string(path)
        .with_context(|| format!("failed to read config file: {}", path.display()))?;
    let mut config: AgentConfig = serde_json::from_str(&raw)
        .with_context(|| format!("failed to parse config file: {}", path.display()))?;
    config.push_server_base_url = normalized_base_url(&config.push_server_base_url)
        .context("push_server_base_url in config is empty")?;
    Ok(Some(config))
}

pub fn save_agent_config(path: &Path, config: &AgentConfig) -> Result<()> {
    let mut normalized = config.clone();
    normalized.push_server_base_url = normalized_base_url(&config.push_server_base_url)
        .context("push_server_base_url is required")?;
    write_json_private(path, &normalized)
}

pub fn ensure_private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)
        .with_context(|| format!("failed to create directory {}", path.display()))?;
    set_dir_mode(path, 0o700)?;
    Ok(())
}

pub fn write_text_file(path: &Path, content: &str, mode: u32) -> Result<()> {
    let parent = path
        .parent()
        .context("file path has no parent directory for write")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("failed to create directory {}", parent.display()))?;

    let tmp_path = temp_path_for(path);
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&tmp_path)
        .with_context(|| format!("failed to open temp file {}", tmp_path.display()))?;
    file.write_all(content.as_bytes())
        .with_context(|| format!("failed to write temp file {}", tmp_path.display()))?;
    file.sync_all()
        .with_context(|| format!("failed to sync temp file {}", tmp_path.display()))?;
    set_file_mode(&tmp_path, mode)?;
    fs::rename(&tmp_path, path)
        .with_context(|| format!("failed to rename temp file {}", path.display()))?;
    set_file_mode(path, mode)?;
    Ok(())
}

pub fn resolve_push_server_base_url(
    cli_value: Option<&str>,
    settings: Option<&AgentSettings>,
    config: Option<&AgentConfig>,
    env_value: Option<&str>,
) -> Option<String> {
    cli_value
        .and_then(normalized_base_url)
        .or_else(|| {
            settings
                .and_then(|s| s.push_server_base_url.as_deref())
                .and_then(normalized_base_url)
        })
        .or_else(|| config.and_then(|c| normalized_base_url(&c.push_server_base_url)))
        .or_else(|| env_value.and_then(normalized_base_url))
}

fn write_json_private<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let parent = path
        .parent()
        .context("config path has no parent directory for write")?;
    ensure_private_dir(parent)?;

    let serialized = serde_json::to_vec_pretty(value).context("failed to serialize JSON")?;
    let tmp_path = temp_path_for(path);

    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&tmp_path)
        .with_context(|| format!("failed to open temp file {}", tmp_path.display()))?;
    file.write_all(&serialized)
        .with_context(|| format!("failed to write temp file {}", tmp_path.display()))?;
    file.write_all(b"\n")
        .with_context(|| format!("failed to finalize temp file {}", tmp_path.display()))?;
    file.sync_all()
        .with_context(|| format!("failed to sync temp file {}", tmp_path.display()))?;

    set_file_mode(&tmp_path, 0o600)?;
    fs::rename(&tmp_path, path)
        .with_context(|| format!("failed to rename temp file {}", path.display()))?;
    set_file_mode(path, 0o600)?;
    Ok(())
}

fn temp_path_for(path: &Path) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    path.with_extension(format!("tmp-{}-{nanos}", std::process::id()))
}

pub fn normalized_base_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.trim_end_matches('/').to_string())
}

#[cfg(unix)]
fn set_dir_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = fs::metadata(path)
        .with_context(|| format!("failed to read metadata {}", path.display()))?
        .permissions();
    perms.set_mode(mode);
    fs::set_permissions(path, perms)
        .with_context(|| format!("failed to set directory permissions {}", path.display()))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_dir_mode(_path: &Path, _mode: u32) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_file_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = fs::metadata(path)
        .with_context(|| format!("failed to read metadata {}", path.display()))?
        .permissions();
    perms.set_mode(mode);
    fs::set_permissions(path, perms)
        .with_context(|| format!("failed to set file permissions {}", path.display()))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_file_mode(_path: &Path, _mode: u32) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn resolves_push_server_url_in_expected_priority() {
        let settings = AgentSettings {
            push_server_base_url: Some("https://settings.example.com".to_string()),
        };
        let config = AgentConfig {
            host_id: "host-id".to_string(),
            ingest_url: "https://push.example.com/v1/events/bell".to_string(),
            ingest_token: "token".to_string(),
            push_server_base_url: "https://config.example.com".to_string(),
            host_name: "host".to_string(),
            platform: "linux-x86_64".to_string(),
            paired_at: Utc::now(),
        };

        let resolved = resolve_push_server_base_url(
            Some(" https://cli.example.com/ "),
            Some(&settings),
            Some(&config),
            Some("https://env.example.com"),
        );
        assert_eq!(resolved.as_deref(), Some("https://cli.example.com"));

        let resolved = resolve_push_server_base_url(
            None,
            Some(&settings),
            Some(&config),
            Some("https://env.example.com"),
        );
        assert_eq!(resolved.as_deref(), Some("https://settings.example.com"));

        let resolved = resolve_push_server_base_url(None, None, Some(&config), Some("https://env.example.com"));
        assert_eq!(resolved.as_deref(), Some("https://config.example.com"));

        let resolved = resolve_push_server_base_url(None, None, None, Some("https://env.example.com/"));
        assert_eq!(resolved.as_deref(), Some("https://env.example.com"));
    }

    #[test]
    fn saves_and_loads_agent_config() {
        let dir = tempdir().expect("tempdir");
        let config_path = dir.path().join("agent.json");
        let config = AgentConfig {
            host_id: "host-id".to_string(),
            ingest_url: "https://push.example.com/v1/events/bell".to_string(),
            ingest_token: "token".to_string(),
            push_server_base_url: "https://push.example.com/".to_string(),
            host_name: "my-mac".to_string(),
            platform: "macos-aarch64".to_string(),
            paired_at: Utc::now(),
        };

        save_agent_config(&config_path, &config).expect("save");
        let loaded = load_agent_config(&config_path)
            .expect("load")
            .expect("present");

        assert_eq!(loaded.host_id, "host-id");
        assert_eq!(loaded.push_server_base_url, "https://push.example.com");
    }
}
