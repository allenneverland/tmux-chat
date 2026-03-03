mod config;
mod daemon;
mod pairing;
mod paths;
mod service;
mod tmux;

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand};
use config::{
    ensure_private_dir, load_agent_config, load_settings, normalized_base_url, save_agent_config,
    save_settings, AgentConfig,
};
use paths::AgentPaths;
use serde::Serialize;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[derive(Parser, Debug)]
#[command(name = "host-agent")]
#[command(version)]
#[command(about = "Host relay agent for Reattach notifications")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Install service and tmux hook integration
    Install {
        /// Push server base URL (e.g. https://push.example.com)
        #[arg(long)]
        push_server_base_url: Option<String>,
    },
    /// Pair host agent with push server
    Pair {
        /// Pairing token issued by push server
        #[arg(long)]
        token: String,
        /// Push server base URL (e.g. https://push.example.com)
        #[arg(long)]
        push_server_base_url: Option<String>,
        /// Output machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// Run host agent daemon
    Run,
    /// Show host agent status
    Status {
        /// Output machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// Internal: send a bell event to local daemon socket
    #[command(name = "emit-bell", hide = true)]
    EmitBell {
        /// Optional tmux pane target (e.g. "dev:0.0")
        #[arg(long)]
        pane_target: Option<String>,
    },
}

#[derive(Debug, Serialize)]
struct PairOutput {
    paired: bool,
    host_id: String,
    host_name: String,
    platform: String,
    push_server_base_url: String,
    ingest_url: String,
    paired_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
struct StatusOutput {
    paired: bool,
    host_id: Option<String>,
    host_name: Option<String>,
    platform: Option<String>,
    push_server_base_url: Option<String>,
    ingest_url: Option<String>,
    paired_at: Option<DateTime<Utc>>,
    config_path: String,
    settings_path: String,
    socket_path: String,
    socket_exists: bool,
    socket_connectable: bool,
    tmux_conf_path: String,
    tmux_hook_configured: bool,
    tmux_hook_active: bool,
    service_manager: String,
    service_unit_path: Option<String>,
    service_installed: bool,
    service_active: Option<bool>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "host_agent=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    if let Err(err) = run().await {
        eprintln!("host-agent error: {:#}", err);
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Install {
            push_server_base_url,
        } => run_install(push_server_base_url).await,
        Commands::Pair {
            token,
            push_server_base_url,
            json,
        } => run_pair(token, push_server_base_url, json).await,
        Commands::Run => run_daemon().await,
        Commands::Status { json } => run_status(json).await,
        Commands::EmitBell { pane_target } => run_emit_bell(pane_target).await,
    }
}

async fn run_install(push_server_base_url: Option<String>) -> Result<()> {
    let paths = AgentPaths::resolve()?;
    ensure_private_dir(&paths.data_dir)?;

    let binary_path = std::env::current_exe().context("failed to resolve current executable path")?;
    tmux::install_bell_hook(&paths.tmux_conf_path, &binary_path)?;
    if let Err(err) = tmux::apply_live_hook(&binary_path) {
        tracing::warn!(error = %err, "failed to apply tmux hook to live server");
    }

    if let Some(raw_url) = push_server_base_url {
        let normalized = normalized_base_url(&raw_url)
            .context("push server base URL is empty after normalization")?;
        let mut settings = load_settings(&paths.settings_path)?;
        settings.push_server_base_url = Some(normalized.clone());
        save_settings(&paths.settings_path, &settings)?;
        println!("Saved push-server base URL: {}", normalized);
    }

    let service_result = service::install_and_start(&paths, &binary_path)?;
    println!("host-agent install complete");
    println!("  tmux config: {}", paths.tmux_conf_path.display());
    println!("  service manager: {}", service_result.manager.as_str());
    if let Some(unit_path) = &service_result.unit_path {
        println!("  service unit: {}", unit_path.display());
    }
    if let Some(err) = service_result.start_error {
        eprintln!("  warning: failed to start service automatically: {}", err);
    }

    Ok(())
}

async fn run_pair(token: String, push_server_base_url: Option<String>, json: bool) -> Result<()> {
    if token.trim().is_empty() {
        anyhow::bail!("pairing token cannot be empty");
    }

    let paths = AgentPaths::resolve()?;
    ensure_private_dir(&paths.data_dir)?;

    let settings = load_settings(&paths.settings_path)?;
    let existing_config = load_agent_config(&paths.config_path)?;
    let env_url = std::env::var("PUSH_SERVER_BASE_URL").ok();

    let base_url = config::resolve_push_server_base_url(
        push_server_base_url.as_deref(),
        Some(&settings),
        existing_config.as_ref(),
        env_url.as_deref(),
    )
    .context(
        "unable to resolve push server base URL; pass --push-server-base-url or set PUSH_SERVER_BASE_URL",
    )?;

    let host_name = detect_host_name();
    let platform = detect_platform();
    let response = pairing::complete_pairing(&base_url, &token, &host_name, &platform).await?;
    let paired_at = Utc::now();

    let agent_config = AgentConfig {
        host_id: response.host_id.clone(),
        ingest_url: response.ingest_url.clone(),
        ingest_token: response.ingest_token,
        push_server_base_url: base_url.clone(),
        host_name: host_name.clone(),
        platform: platform.clone(),
        paired_at,
    };
    save_agent_config(&paths.config_path, &agent_config)?;

    let mut updated_settings = settings;
    updated_settings.push_server_base_url = Some(base_url.clone());
    save_settings(&paths.settings_path, &updated_settings)?;

    let output = PairOutput {
        paired: true,
        host_id: response.host_id,
        host_name,
        platform,
        push_server_base_url: base_url,
        ingest_url: response.ingest_url,
        paired_at,
    };

    if json {
        print_json(&output)?;
    } else {
        println!("host-agent pairing complete");
        println!("  host_id: {}", output.host_id);
        println!("  ingest_url: {}", output.ingest_url);
        println!("  push_server_base_url: {}", output.push_server_base_url);
        println!("  paired_at: {}", output.paired_at.to_rfc3339());
    }

    Ok(())
}

async fn run_daemon() -> Result<()> {
    let paths = AgentPaths::resolve()?;
    let config = load_agent_config(&paths.config_path)?
        .context("host-agent is not paired; run `host-agent pair --token <token>` first")?;
    daemon::run(&paths, config).await
}

async fn run_status(json: bool) -> Result<()> {
    let paths = AgentPaths::resolve()?;
    let settings = load_settings(&paths.settings_path)?;
    let config = load_agent_config(&paths.config_path)?;

    let service_status = service::inspect(&paths);
    let tmux_hook_configured = tmux::is_hook_configured(&paths.tmux_conf_path)?;
    let tmux_hook_active = tmux::is_live_hook_active();
    let socket_exists = paths.socket_path.exists();
    let socket_connectable = if socket_exists {
        daemon::is_socket_connectable(&paths.socket_path).await
    } else {
        false
    };

    let output = StatusOutput {
        paired: config.is_some(),
        host_id: config.as_ref().map(|c| c.host_id.clone()),
        host_name: config.as_ref().map(|c| c.host_name.clone()),
        platform: config.as_ref().map(|c| c.platform.clone()),
        push_server_base_url: settings
            .push_server_base_url
            .clone()
            .or_else(|| config.as_ref().map(|c| c.push_server_base_url.clone())),
        ingest_url: config.as_ref().map(|c| c.ingest_url.clone()),
        paired_at: config.as_ref().map(|c| c.paired_at.clone()),
        config_path: paths.config_path.display().to_string(),
        settings_path: paths.settings_path.display().to_string(),
        socket_path: paths.socket_path.display().to_string(),
        socket_exists,
        socket_connectable,
        tmux_conf_path: paths.tmux_conf_path.display().to_string(),
        tmux_hook_configured,
        tmux_hook_active,
        service_manager: service_status.manager.as_str().to_string(),
        service_unit_path: service_status
            .unit_path
            .as_ref()
            .map(|p| p.display().to_string()),
        service_installed: service_status.installed,
        service_active: service_status.active,
    };

    if json {
        print_json(&output)?;
    } else {
        println!("host-agent status");
        println!("  paired: {}", output.paired);
        if let Some(host_id) = &output.host_id {
            println!("  host_id: {}", host_id);
        }
        if let Some(url) = &output.push_server_base_url {
            println!("  push_server_base_url: {}", url);
        }
        println!(
            "  daemon_socket: {} (exists={}, connectable={})",
            output.socket_path, output.socket_exists, output.socket_connectable
        );
        println!(
            "  tmux_hook: configured={}, active={}",
            output.tmux_hook_configured, output.tmux_hook_active
        );
        println!(
            "  service: manager={}, installed={}, active={}",
            output.service_manager,
            output.service_installed,
            output
                .service_active
                .map(|v| v.to_string())
                .unwrap_or_else(|| "unknown".to_string())
        );
    }

    Ok(())
}

async fn run_emit_bell(pane_target: Option<String>) -> Result<()> {
    let paths = AgentPaths::resolve()?;
    let _ = daemon::emit(&paths, pane_target).await?;
    Ok(())
}

fn detect_host_name() -> String {
    match hostname::get() {
        Ok(name) => {
            let value = name.to_string_lossy().trim().to_string();
            if value.is_empty() {
                "unknown-host".to_string()
            } else {
                value
            }
        }
        Err(_) => "unknown-host".to_string(),
    }
}

fn detect_platform() -> String {
    format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH)
}

fn print_json<T: Serialize>(value: &T) -> Result<()> {
    let serialized = serde_json::to_string_pretty(value).context("failed to serialize JSON output")?;
    println!("{}", serialized);
    Ok(())
}
