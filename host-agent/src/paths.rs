use std::path::PathBuf;

use anyhow::{Context, Result};

#[derive(Debug, Clone)]
pub struct AgentPaths {
    pub data_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub config_path: PathBuf,
    pub settings_path: PathBuf,
    pub socket_path: PathBuf,
    pub tmux_conf_path: PathBuf,
    pub launchd_plist_path: PathBuf,
    pub launchd_log_dir: PathBuf,
    pub systemd_service_path: PathBuf,
}

impl AgentPaths {
    pub fn resolve() -> Result<Self> {
        let home = dirs::home_dir().context("failed to resolve home directory")?;

        let data_dir = dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("tmux-chat")
            .join("host-agent");

        let runtime_base = dirs::runtime_dir().unwrap_or_else(|| data_dir.join("run"));
        let runtime_dir = runtime_base.join("tmux-chat-host-agent");

        let config_path = data_dir.join("agent.json");
        let settings_path = data_dir.join("settings.json");
        let socket_path = runtime_dir.join("bell.sock");
        let tmux_conf_path = home.join(".tmux.conf");
        let launchd_plist_path = home
            .join("Library")
            .join("LaunchAgents")
            .join("io.tmux-chat.host-agent.plist");
        let launchd_log_dir = home.join("Library").join("Logs").join("TmuxChat");
        let systemd_service_path = home
            .join(".config")
            .join("systemd")
            .join("user")
            .join("tmux-chat-host-agent.service");

        Ok(Self {
            data_dir,
            runtime_dir,
            config_path,
            settings_path,
            socket_path,
            tmux_conf_path,
            launchd_plist_path,
            launchd_log_dir,
            systemd_service_path,
        })
    }
}
