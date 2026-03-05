use std::{
    path::{Path, PathBuf},
    process::{Command, Output},
};

use anyhow::{Context, Result};

use crate::{config::write_text_file, paths::AgentPaths};

const LAUNCHD_LABEL: &str = "io.tmux-chat.host-agent";
const SYSTEMD_UNIT_NAME: &str = "tmux-chat-host-agent.service";

#[derive(Debug, Clone, Copy)]
pub enum ServiceManager {
    LaunchdUser,
    SystemdUser,
    Unsupported,
}

impl ServiceManager {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LaunchdUser => "launchd-user",
            Self::SystemdUser => "systemd-user",
            Self::Unsupported => "unsupported",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServiceInstallResult {
    pub manager: ServiceManager,
    pub unit_path: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct ServiceStatus {
    pub manager: ServiceManager,
    pub unit_path: Option<PathBuf>,
    pub installed: bool,
    pub active: Option<bool>,
}

pub fn install(paths: &AgentPaths, binary_path: &Path) -> Result<ServiceInstallResult> {
    match manager_for_current_platform() {
        ServiceManager::LaunchdUser => install_launchd(paths, binary_path),
        ServiceManager::SystemdUser => install_systemd(paths, binary_path),
        ServiceManager::Unsupported => Ok(ServiceInstallResult {
            manager: ServiceManager::Unsupported,
            unit_path: None,
        }),
    }
}

pub fn start_or_restart(paths: &AgentPaths) -> Result<()> {
    match manager_for_current_platform() {
        ServiceManager::LaunchdUser => start_or_restart_launchd(paths),
        ServiceManager::SystemdUser => start_or_restart_systemd(paths),
        ServiceManager::Unsupported => {
            anyhow::bail!("unsupported platform for host-agent service management")
        }
    }
}

pub fn inspect(paths: &AgentPaths) -> ServiceStatus {
    match manager_for_current_platform() {
        ServiceManager::LaunchdUser => inspect_launchd(paths),
        ServiceManager::SystemdUser => inspect_systemd(paths),
        ServiceManager::Unsupported => ServiceStatus {
            manager: ServiceManager::Unsupported,
            unit_path: None,
            installed: false,
            active: None,
        },
    }
}

fn manager_for_current_platform() -> ServiceManager {
    #[cfg(target_os = "macos")]
    {
        return ServiceManager::LaunchdUser;
    }

    #[cfg(target_os = "linux")]
    {
        return ServiceManager::SystemdUser;
    }

    #[allow(unreachable_code)]
    ServiceManager::Unsupported
}

fn install_launchd(paths: &AgentPaths, binary_path: &Path) -> Result<ServiceInstallResult> {
    let plist_path = &paths.launchd_plist_path;
    let stdout_log = paths.launchd_log_dir.join("host-agent.log");
    let stderr_log = paths.launchd_log_dir.join("host-agent.error.log");
    std::fs::create_dir_all(&paths.launchd_log_dir)
        .with_context(|| format!("failed to create {}", paths.launchd_log_dir.display()))?;

    let plist = launchd_plist(binary_path, &stdout_log, &stderr_log);
    write_text_file(plist_path, &plist, 0o644)?;

    Ok(ServiceInstallResult {
        manager: ServiceManager::LaunchdUser,
        unit_path: Some(plist_path.clone()),
    })
}

fn install_systemd(paths: &AgentPaths, binary_path: &Path) -> Result<ServiceInstallResult> {
    let service_path = &paths.systemd_service_path;
    let service = systemd_unit(binary_path);
    write_text_file(service_path, &service, 0o644)?;

    run_command_ok("systemctl", &["--user", "daemon-reload"])?;

    Ok(ServiceInstallResult {
        manager: ServiceManager::SystemdUser,
        unit_path: Some(service_path.clone()),
    })
}

fn start_or_restart_launchd(paths: &AgentPaths) -> Result<()> {
    if !paths.launchd_plist_path.exists() {
        anyhow::bail!(
            "launchd plist is missing at {}; run `host-agent install` first",
            paths.launchd_plist_path.display()
        );
    }

    let _ = Command::new("launchctl")
        .arg("unload")
        .arg(&paths.launchd_plist_path)
        .output();

    let load_output = Command::new("launchctl")
        .arg("load")
        .arg(&paths.launchd_plist_path)
        .output()
        .context("failed to execute launchctl load")?;
    if !load_output.status.success() {
        anyhow::bail!("launchctl load failed: {}", stderr_or_stdout(&load_output));
    }

    let _ = Command::new("launchctl")
        .arg("start")
        .arg(LAUNCHD_LABEL)
        .output();

    let status = inspect_launchd(paths);
    if status.active != Some(true) {
        anyhow::bail!("launchd service is not active after reload");
    }
    Ok(())
}

fn start_or_restart_systemd(paths: &AgentPaths) -> Result<()> {
    if !paths.systemd_service_path.exists() {
        anyhow::bail!(
            "systemd unit is missing at {}; run `host-agent install` first",
            paths.systemd_service_path.display()
        );
    }

    run_command_ok("systemctl", &["--user", "daemon-reload"])?;
    run_command_ok(
        "systemctl",
        &["--user", "enable", "--now", SYSTEMD_UNIT_NAME],
    )?;
    run_command_ok("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;

    let active_output = Command::new("systemctl")
        .args(["--user", "is-active", SYSTEMD_UNIT_NAME])
        .output()
        .context("failed to execute systemctl --user is-active")?;
    let active_value = String::from_utf8_lossy(&active_output.stdout).trim().to_string();
    if !active_output.status.success() || active_value != "active" {
        anyhow::bail!("systemd service is not active: {}", stderr_or_stdout(&active_output));
    }

    Ok(())
}

fn inspect_launchd(paths: &AgentPaths) -> ServiceStatus {
    let installed = paths.launchd_plist_path.exists();
    let active = match Command::new("launchctl").arg("list").output() {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            Some(stdout.lines().any(|line| line.contains(LAUNCHD_LABEL)))
        }
        _ => None,
    };

    ServiceStatus {
        manager: ServiceManager::LaunchdUser,
        unit_path: Some(paths.launchd_plist_path.clone()),
        installed,
        active,
    }
}

fn inspect_systemd(paths: &AgentPaths) -> ServiceStatus {
    let installed = paths.systemd_service_path.exists();
    let active = match Command::new("systemctl")
        .args(["--user", "is-active", SYSTEMD_UNIT_NAME])
        .output()
    {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            Some(out.status.success() && stdout.trim() == "active")
        }
        Err(_) => None,
    };

    ServiceStatus {
        manager: ServiceManager::SystemdUser,
        unit_path: Some(paths.systemd_service_path.clone()),
        installed,
        active,
    }
}

fn run_command_ok(cmd: &str, args: &[&str]) -> Result<()> {
    let output = Command::new(cmd)
        .args(args)
        .output()
        .with_context(|| format!("failed to execute command: {} {}", cmd, args.join(" ")))?;

    if !output.status.success() {
        anyhow::bail!("{} {}", cmd, stderr_or_stdout(&output));
    }
    Ok(())
}

fn stderr_or_stdout(output: &Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stderr.is_empty() {
        return stderr;
    }
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn launchd_plist(binary_path: &Path, stdout_log: &Path, stderr_log: &Path) -> String {
    let binary = xml_escape(&binary_path.to_string_lossy());
    let stdout_path = xml_escape(&stdout_log.to_string_lossy());
    let stderr_path = xml_escape(&stderr_log.to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{binary}</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{stdout_path}</string>
    <key>StandardErrorPath</key>
    <string>{stderr_path}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
"#
    )
}

fn systemd_unit(binary_path: &Path) -> String {
    let binary = binary_path
        .to_string_lossy()
        .replace('\\', "\\\\")
        .replace('"', "\\\"");
    format!(
        r#"[Unit]
Description=TmuxChat Host Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="{}" run
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
"#,
        binary
    )
}

fn xml_escape(input: &str) -> String {
    input
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
