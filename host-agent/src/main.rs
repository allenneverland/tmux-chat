mod config;
mod daemon;
mod pairing;
mod paths;
mod service;
mod shell_notify;
mod tmux;

use std::time::Duration;

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

const STATUS_SCHEMA_VERSION: u32 = 2;

#[derive(Parser, Debug)]
#[command(name = "host-agent")]
#[command(version)]
#[command(about = "Host relay agent for TmuxChat notifications")]
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
    /// Install Bash command-finish auto-notify hook
    #[command(name = "install-shell-notify")]
    InstallShellNotify {
        /// Notify only when command runtime reaches this threshold (seconds)
        #[arg(long, default_value_t = 3)]
        min_seconds: u64,
    },
    /// Remove Bash command-finish auto-notify hook
    #[command(name = "uninstall-shell-notify")]
    UninstallShellNotify,
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
struct StatusFeatures {
    bash_auto_notify_runtime_probe: bool,
}

#[derive(Debug, Serialize)]
struct StatusOutput {
    daemon: String,
    version: String,
    status_schema_version: u32,
    features: StatusFeatures,
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
    tmux_monitor_bell: Option<String>,
    tmux_bell_action: Option<String>,
    bashrc_path: String,
    bash_auto_notify_script_path: String,
    bash_auto_notify_configured: bool,
    bash_startup_files_configured: Vec<String>,
    bash_auto_notify_runtime_probe: Option<bool>,
    bash_runtime_probe_detail: Option<String>,
    bash_binary_path: Option<String>,
    notification_ready: bool,
    readiness_errors: Vec<String>,
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
        Commands::InstallShellNotify { min_seconds } => run_install_shell_notify(min_seconds),
        Commands::UninstallShellNotify => run_uninstall_shell_notify(),
        Commands::EmitBell { pane_target } => run_emit_bell(pane_target).await,
    }
}

async fn run_install(push_server_base_url: Option<String>) -> Result<()> {
    let paths = AgentPaths::resolve()?;
    ensure_private_dir(&paths.data_dir)?;

    let binary_path =
        std::env::current_exe().context("failed to resolve current executable path")?;
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

    let service_result = service::install(&paths, &binary_path)?;
    let paired_config = load_agent_config(&paths.config_path)?;
    let mut socket_ready = false;
    if paired_config.is_some() {
        service::start_or_restart(&paths)
            .context("failed to start host-agent service after install")?;
        socket_ready =
            daemon::wait_for_socket_connectable(&paths.socket_path, Duration::from_secs(10)).await;
        if !socket_ready {
            anyhow::bail!(
                "host-agent service did not become ready after install; check service logs and rerun `host-agent status --json`"
            );
        }
    }

    println!("host-agent install complete");
    println!("  tmux config: {}", paths.tmux_conf_path.display());
    println!("  service manager: {}", service_result.manager.as_str());
    if let Some(unit_path) = &service_result.unit_path {
        println!("  service unit: {}", unit_path.display());
    }
    if paired_config.is_some() {
        println!("  service socket ready: {}", socket_ready);
    } else {
        println!("  service start deferred until pairing completes");
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

    service::start_or_restart(&paths)
        .context("failed to start host-agent service after pairing")?;
    let socket_ready =
        daemon::wait_for_socket_connectable(&paths.socket_path, Duration::from_secs(10)).await;
    if !socket_ready {
        anyhow::bail!(
            "host-agent service did not become ready after pairing; check service logs and rerun `host-agent status --json`"
        );
    }

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
    let tmux_monitor_bell = tmux::monitor_bell_value();
    let tmux_bell_action = tmux::bell_action_value();
    let bash_auto_notify_configured = shell_notify::is_bash_auto_notify_configured(&paths)?;
    let bash_startup_files_configured = shell_notify::configured_bash_startup_files(&paths)?
        .into_iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>();
    let bash_probe = shell_notify::bash_runtime_probe(&paths);
    let bash_auto_notify_runtime_probe = bash_probe.success;
    let bash_runtime_probe_detail = Some(bash_probe.detail.clone());
    let bash_binary_path = bash_probe
        .bash_binary_path
        .as_ref()
        .map(|p| p.display().to_string());
    let socket_exists = paths.socket_path.exists();
    let socket_connectable = if socket_exists {
        daemon::is_socket_connectable(&paths.socket_path).await
    } else {
        false
    };
    let mut readiness_errors = Vec::new();
    if config.is_none() {
        readiness_errors.push("not_paired".to_string());
    }
    if !socket_exists {
        readiness_errors.push("daemon_socket_missing".to_string());
    }
    if !socket_connectable {
        readiness_errors.push("daemon_socket_unreachable".to_string());
    }
    if !tmux_hook_active {
        readiness_errors.push("tmux_alert_bell_hook_inactive".to_string());
    }
    match tmux_monitor_bell.as_deref() {
        Some("on") => {}
        Some(other) => readiness_errors.push(format!("tmux_monitor_bell_not_on:{other}")),
        None => readiness_errors.push("tmux_monitor_bell_unknown".to_string()),
    }
    match tmux_bell_action.as_deref() {
        Some("any") => {}
        Some(other) => readiness_errors.push(format!("tmux_bell_action_not_any:{other}")),
        None => readiness_errors.push("tmux_bell_action_unknown".to_string()),
    }
    if !bash_auto_notify_configured {
        readiness_errors.push("bash_auto_notify_not_configured".to_string());
    }
    match bash_auto_notify_runtime_probe {
        Some(true) => {}
        Some(false) => readiness_errors.push("bash_auto_notify_runtime_probe_failed".to_string()),
        None => readiness_errors.push("bash_auto_notify_runtime_probe_unavailable".to_string()),
    }
    match service_status.manager {
        service::ServiceManager::Unsupported => {}
        _ => {
            if service_status.active != Some(true) {
                readiness_errors.push("service_not_active".to_string());
            }
        }
    }
    let notification_ready = readiness_errors.is_empty();

    let output = StatusOutput {
        daemon: "host-agent".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        status_schema_version: STATUS_SCHEMA_VERSION,
        features: StatusFeatures {
            bash_auto_notify_runtime_probe: true,
        },
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
        tmux_monitor_bell,
        tmux_bell_action,
        bashrc_path: paths.bashrc_path.display().to_string(),
        bash_auto_notify_script_path: paths.bash_auto_notify_script_path.display().to_string(),
        bash_auto_notify_configured,
        bash_startup_files_configured,
        bash_auto_notify_runtime_probe,
        bash_runtime_probe_detail,
        bash_binary_path,
        notification_ready,
        readiness_errors,
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
        println!(
            "  identity: daemon={}, version={}, status_schema_version={}",
            output.daemon, output.version, output.status_schema_version
        );
        println!(
            "  features: bash_auto_notify_runtime_probe={}",
            output.features.bash_auto_notify_runtime_probe
        );
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
            "  tmux_bell_options: monitor_bell={:?}, bell_action={:?}",
            output.tmux_monitor_bell, output.tmux_bell_action
        );
        println!(
            "  bash_auto_notify: configured={}, runtime_probe={:?}, probe_detail={:?}, bash_binary_path={:?}, bashrc={}, script={}",
            output.bash_auto_notify_configured,
            output.bash_auto_notify_runtime_probe,
            output.bash_runtime_probe_detail,
            output.bash_binary_path,
            output.bashrc_path,
            output.bash_auto_notify_script_path
        );
        if !output.bash_startup_files_configured.is_empty() {
            println!(
                "  bash_startup_files_configured: {}",
                output.bash_startup_files_configured.join(", ")
            );
        }
        println!(
            "  service: manager={}, installed={}, active={}",
            output.service_manager,
            output.service_installed,
            output
                .service_active
                .map(|v| v.to_string())
                .unwrap_or_else(|| "unknown".to_string())
        );
        println!("  notification_ready: {}", output.notification_ready);
        if !output.readiness_errors.is_empty() {
            println!("  readiness_errors: {}", output.readiness_errors.join(", "));
        }
    }

    Ok(())
}

async fn run_emit_bell(pane_target: Option<String>) -> Result<()> {
    let paths = AgentPaths::resolve()?;
    let _ = daemon::emit(&paths, pane_target).await?;
    Ok(())
}

fn run_install_shell_notify(min_seconds: u64) -> Result<()> {
    let paths = AgentPaths::resolve()?;
    let bash_binary = shell_notify::detect_bash_binary().map_err(|reason| {
        anyhow::anyhow!(
            "bash runtime is unavailable ({reason}); install bash and ensure it is executable from non-interactive SSH sessions"
        )
    })?;
    let binary_path =
        std::env::current_exe().context("failed to resolve current executable path")?;
    let result = shell_notify::install_bash_auto_notify(&paths, &binary_path, min_seconds)?;
    let probe = shell_notify::bash_runtime_probe(&paths);
    if probe.success != Some(true) {
        let bash_path = probe
            .bash_binary_path
            .as_ref()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "unknown".to_string());
        anyhow::bail!(
            "bash auto-notify runtime probe failed after install (detail={}, bash_binary_path={})",
            probe.detail,
            bash_path
        );
    }

    println!("bash auto-notify install complete");
    println!("  min_seconds: {}", min_seconds.max(1));
    println!("  bashrc: {}", result.bashrc_path.display());
    println!("  login_startup: {}", result.login_startup_path.display());
    println!("  script: {}", result.script_path.display());
    println!("  bash_binary_path: {}", bash_binary.display());
    if !result.startup_files_updated.is_empty() {
        let rendered = result
            .startup_files_updated
            .iter()
            .map(|path| path.display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        println!("  startup_files_updated: {}", rendered);
    }
    Ok(())
}

fn run_uninstall_shell_notify() -> Result<()> {
    let paths = AgentPaths::resolve()?;
    let result = shell_notify::uninstall_bash_auto_notify(&paths)?;
    println!("bash auto-notify uninstall complete");
    println!("  bashrc: {}", result.bashrc_path.display());
    println!("  script: {}", result.script_path.display());
    if !result.startup_files_updated.is_empty() {
        let rendered = result
            .startup_files_updated
            .iter()
            .map(|path| path.display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        println!("  startup_files_updated: {}", rendered);
    }
    println!("  script_removed: {}", result.script_removed);
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
    let serialized =
        serde_json::to_string_pretty(value).context("failed to serialize JSON output")?;
    println!("{}", serialized);
    Ok(())
}
