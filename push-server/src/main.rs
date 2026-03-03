use std::net::SocketAddr;

use axum::{routing::get, Router};
use clap::Parser;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const DEFAULT_PORT: u16 = 8790;
const DEFAULT_BIND_ADDR: &str = "127.0.0.1";

#[derive(Parser, Debug)]
#[command(name = "push-server")]
#[command(version)]
#[command(about = "Push server for Reattach notification pipeline")]
struct Cli {
    /// Bind address
    #[arg(long, env = "PUSH_SERVER_BIND_ADDR", default_value = DEFAULT_BIND_ADDR)]
    bind_addr: String,

    /// Listen port
    #[arg(long, env = "PUSH_SERVER_PORT", default_value_t = DEFAULT_PORT)]
    port: u16,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "push_server=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let cli = Cli::parse();
    let addr: SocketAddr = format!("{}:{}", cli.bind_addr, cli.port)
        .parse()
        .expect("Invalid bind address");

    let app = Router::new().route("/healthz", get(healthz));

    tracing::info!("starting push-server on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind TCP listener");

    axum::serve(listener, app)
        .await
        .expect("Failed to start push-server");
}

async fn healthz() -> &'static str {
    "ok"
}

