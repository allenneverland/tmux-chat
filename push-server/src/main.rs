mod api;
mod apns;
mod config;
mod db;
mod error;
mod metrics;
mod models;
mod state;
mod token;

use std::{net::SocketAddr, sync::Arc};

use axum::{routing::{delete, get, post}, Router};
use clap::Parser;
use config::{Cli, Config};
use db::Database;
use error::AppResult;
use metrics::Metrics;
use state::AppState;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "push_server=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    if let Err(err) = run().await {
        tracing::error!("fatal error: {}", err);
        std::process::exit(1);
    }
}

async fn run() -> AppResult<()> {
    let cli = Cli::parse();
    let config = Arc::new(Config::from_cli(cli));

    std::fs::create_dir_all(&config.data_dir)?;
    let db = Arc::new(Database::new(&config.db_path)?);

    if let Some(token) = &config.compat_notify_token {
        db.bootstrap_compat_token(token)?;
        tracing::info!("compat notify token configured");
    }

    let imported = db.import_legacy_device_tokens_once(config.legacy_device_tokens_file.as_deref())?;
    if imported > 0 {
        tracing::info!(imported, "imported legacy APNs device tokens");
    }

    let apns = if let Some(apns_config) = &config.apns {
        match apns::ApnsService::new(apns_config) {
            Ok(service) => {
                tracing::info!("APNs service initialized");
                Some(Arc::new(service))
            }
            Err(e) => {
                tracing::warn!("failed to initialize APNs service: {}", e);
                None
            }
        }
    } else {
        tracing::warn!("APNs credentials are not configured; events will be accepted but not delivered");
        None
    };

    let state = AppState {
        config: config.clone(),
        db,
        apns,
        metrics: Arc::new(Metrics::default()),
    };

    let app = Router::new()
        .route("/healthz", get(api::healthz))
        .route("/metrics", get(api::metrics))
        .route("/v1/pairings/start", post(api::start_pairing))
        .route("/v1/pairings/complete", post(api::complete_pairing))
        .route("/v1/devices/register", post(api::register_device))
        .route("/v1/events/bell", post(api::ingest_bell))
        .route("/v1/events/agent", post(api::ingest_agent))
        .route("/v1/mutes", post(api::create_mute))
        .route("/v1/mutes/{id}", delete(api::delete_mute))
        .with_state(state);

    let addr: SocketAddr = format!("{}:{}", config.bind_addr, config.port)
        .parse()
        .map_err(|e| error::AppError::internal(format!("invalid bind address: {}", e)))?;

    tracing::info!("starting push-server on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| error::AppError::internal(format!("bind failed: {}", e)))?;

    axum::serve(listener, app)
        .await
        .map_err(|e| error::AppError::internal(format!("server failed: {}", e)))
}
