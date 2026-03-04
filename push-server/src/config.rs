use std::path::PathBuf;

use clap::Parser;

const DEFAULT_PORT: u16 = 8790;
const DEFAULT_BIND_ADDR: &str = "127.0.0.1";
const DEFAULT_PAIRING_TTL_SECONDS: i64 = 600;

#[derive(Parser, Debug)]
#[command(name = "push-server")]
#[command(version)]
#[command(about = "Push server for TmuxChat notification pipeline")]
pub struct Cli {
    /// Bind address
    #[arg(long, env = "PUSH_SERVER_BIND_ADDR", default_value = DEFAULT_BIND_ADDR)]
    pub bind_addr: String,

    /// Listen port
    #[arg(long, env = "PUSH_SERVER_PORT", default_value_t = DEFAULT_PORT)]
    pub port: u16,

    /// Data directory for sqlite and runtime state
    #[arg(long, env = "PUSH_SERVER_DATA_DIR")]
    pub data_dir: Option<PathBuf>,

    /// External base URL announced to clients (for ingest_url in pairing complete)
    #[arg(long, env = "PUSH_SERVER_PUBLIC_BASE_URL")]
    pub public_base_url: Option<String>,

    /// Pairing token TTL in seconds
    #[arg(long, env = "PUSH_SERVER_PAIRING_TTL_SECONDS", default_value_t = DEFAULT_PAIRING_TTL_SECONDS)]
    pub pairing_ttl_seconds: i64,

    /// Optional legacy device token file for one-time import
    #[arg(long, env = "PUSH_SERVER_LEGACY_DEVICE_TOKENS_FILE")]
    pub legacy_device_tokens_file: Option<PathBuf>,

    /// Optional static token used by tmux-chatd /notify compatibility forwarding
    #[arg(long, env = "PUSH_SERVER_COMPAT_NOTIFY_TOKEN")]
    pub compat_notify_token: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub bind_addr: String,
    pub port: u16,
    pub data_dir: PathBuf,
    pub db_path: PathBuf,
    pub public_base_url: String,
    pub pairing_ttl_seconds: i64,
    pub legacy_device_tokens_file: Option<PathBuf>,
    pub compat_notify_token: Option<String>,
    pub apns: Option<ApnsConfig>,
}

#[derive(Clone, Debug)]
pub struct ApnsConfig {
    pub key_base64: String,
    pub key_id: String,
    pub team_id: String,
    pub bundle_id: String,
}

impl Config {
    pub fn from_cli(cli: Cli) -> Self {
        let data_dir = cli.data_dir.unwrap_or_else(default_data_dir);
        let db_path = data_dir.join("push-server.sqlite3");
        let public_base_url = cli
            .public_base_url
            .unwrap_or_else(|| format!("http://{}:{}", cli.bind_addr, cli.port));
        let legacy_device_tokens_file = cli
            .legacy_device_tokens_file
            .or_else(default_legacy_device_tokens_file);

        let apns = match (
            std::env::var("APNS_KEY_BASE64").ok(),
            std::env::var("APNS_KEY_ID").ok(),
            std::env::var("APNS_TEAM_ID").ok(),
            std::env::var("APNS_BUNDLE_ID").ok(),
        ) {
            (Some(key_base64), Some(key_id), Some(team_id), Some(bundle_id)) => Some(ApnsConfig {
                key_base64,
                key_id,
                team_id,
                bundle_id,
            }),
            _ => None,
        };

        Self {
            bind_addr: cli.bind_addr,
            port: cli.port,
            data_dir,
            db_path,
            public_base_url,
            pairing_ttl_seconds: cli.pairing_ttl_seconds.max(60),
            legacy_device_tokens_file,
            compat_notify_token: cli.compat_notify_token,
            apns,
        }
    }

    pub fn ingest_url(&self) -> String {
        format!("{}/v1/events/bell", self.public_base_url.trim_end_matches('/'))
    }
}

fn default_data_dir() -> PathBuf {
    if let Ok(path) = std::env::var("PUSH_SERVER_DATA_DIR") {
        return PathBuf::from(path);
    }

    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("tmux-chat")
        .join("push-server")
}

fn default_legacy_device_tokens_file() -> Option<PathBuf> {
    let path = dirs::data_local_dir()?
        .join("tmux-chatd")
        .join("device_tokens.json");
    if path.exists() {
        Some(path)
    } else {
        None
    }
}
