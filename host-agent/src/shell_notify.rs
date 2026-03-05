use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result};

use crate::{config::write_text_file, paths::AgentPaths};

pub const BASH_MANAGED_BLOCK_START: &str = "# >>> TMUX-CHAT BASH AUTO-NOTIFY START >>>";
pub const BASH_MANAGED_BLOCK_END: &str = "# <<< TMUX-CHAT BASH AUTO-NOTIFY END <<<";
pub const BASH_MANAGED_BLOCK_START_SUFFIX: &str = "BASH AUTO-NOTIFY START >>>";
pub const BASH_MANAGED_BLOCK_END_SUFFIX: &str = "BASH AUTO-NOTIFY END <<<";

#[derive(Debug, Clone)]
pub struct BashAutoNotifyInstallResult {
    pub bashrc_path: PathBuf,
    pub login_startup_path: PathBuf,
    pub script_path: PathBuf,
    pub startup_files_updated: Vec<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct BashAutoNotifyUninstallResult {
    pub bashrc_path: PathBuf,
    pub script_path: PathBuf,
    pub startup_files_updated: Vec<PathBuf>,
    pub script_removed: bool,
}

pub fn install_bash_auto_notify(
    paths: &AgentPaths,
    binary_path: &Path,
    min_seconds: u64,
) -> Result<BashAutoNotifyInstallResult> {
    let threshold = min_seconds.max(1);
    let script = render_bash_script(binary_path, threshold);
    let script_parent = paths
        .bash_auto_notify_script_path
        .parent()
        .context("bash auto-notify script path has no parent")?;
    fs::create_dir_all(script_parent)
        .with_context(|| format!("failed to create {}", script_parent.display()))?;
    write_text_file(&paths.bash_auto_notify_script_path, &script, 0o644)?;

    let login_startup_path = login_startup_path_for_install(paths);
    let managed = render_startup_managed_block(&paths.bash_auto_notify_script_path);
    let mut startup_files_updated = Vec::new();
    for startup_path in install_target_startup_paths(paths) {
        let existing = if startup_path.exists() {
            fs::read_to_string(&startup_path)
                .with_context(|| format!("failed to read {}", startup_path.display()))?
        } else {
            String::new()
        };
        let updated = upsert_managed_block(&existing, &managed);
        if updated != existing {
            write_text_file(&startup_path, &updated, 0o644)?;
            startup_files_updated.push(startup_path);
        }
    }

    Ok(BashAutoNotifyInstallResult {
        bashrc_path: paths.bashrc_path.clone(),
        login_startup_path,
        script_path: paths.bash_auto_notify_script_path.clone(),
        startup_files_updated,
    })
}

pub fn uninstall_bash_auto_notify(paths: &AgentPaths) -> Result<BashAutoNotifyUninstallResult> {
    let mut startup_files_updated = Vec::new();
    for startup_path in all_candidate_startup_paths(paths) {
        if !startup_path.exists() {
            continue;
        }
        let existing = fs::read_to_string(&startup_path)
            .with_context(|| format!("failed to read {}", startup_path.display()))?;
        let updated = remove_managed_block(&existing);
        if updated != existing {
            write_text_file(&startup_path, &updated, 0o644)?;
            startup_files_updated.push(startup_path);
        }
    }

    let script_removed = if paths.bash_auto_notify_script_path.exists() {
        fs::remove_file(&paths.bash_auto_notify_script_path).with_context(|| {
            format!(
                "failed to remove {}",
                paths.bash_auto_notify_script_path.display()
            )
        })?;
        true
    } else {
        false
    };

    Ok(BashAutoNotifyUninstallResult {
        bashrc_path: paths.bashrc_path.clone(),
        script_path: paths.bash_auto_notify_script_path.clone(),
        startup_files_updated,
        script_removed,
    })
}

pub fn configured_bash_startup_files(paths: &AgentPaths) -> Result<Vec<PathBuf>> {
    let mut configured = Vec::new();
    for startup_path in all_candidate_startup_paths(paths) {
        if !startup_path.exists() {
            continue;
        }
        let content = fs::read_to_string(&startup_path)
            .with_context(|| format!("failed to read {}", startup_path.display()))?;
        if find_any_managed_block_range(&content).is_some()
            && content.contains("bash-auto-notify.sh")
        {
            configured.push(startup_path);
        }
    }
    Ok(configured)
}

pub fn is_bash_auto_notify_configured(paths: &AgentPaths) -> Result<bool> {
    if !paths.bash_auto_notify_script_path.exists() {
        return Ok(false);
    }
    Ok(!configured_bash_startup_files(paths)?.is_empty())
}

#[derive(Debug, Clone)]
pub struct BashRuntimeProbeResult {
    pub success: Option<bool>,
    pub detail: String,
    pub bash_binary_path: Option<PathBuf>,
}

pub fn detect_bash_binary() -> std::result::Result<PathBuf, String> {
    if let Some(path) = bash_from_command_v() {
        return Ok(path);
    }

    for candidate in [
        "/bin/bash",
        "/usr/bin/bash",
        "/usr/local/bin/bash",
        "/opt/homebrew/bin/bash",
    ] {
        let path = PathBuf::from(candidate);
        if path.is_file() {
            return Ok(path);
        }
    }

    Err("not_found".to_string())
}

pub fn bash_runtime_probe(paths: &AgentPaths) -> BashRuntimeProbeResult {
    let bash_binary = match detect_bash_binary() {
        Ok(path) => path,
        Err(reason) => {
            return BashRuntimeProbeResult {
                success: None,
                detail: format!("unavailable:{reason}"),
                bash_binary_path: None,
            };
        }
    };

    if !paths.bash_auto_notify_script_path.exists() {
        return BashRuntimeProbeResult {
            success: Some(false),
            detail: "failed:script_missing".to_string(),
            bash_binary_path: Some(bash_binary),
        };
    }

    let quoted_script_path = shell_quote(&paths.bash_auto_notify_script_path.to_string_lossy());
    let probe_command = format!(
        "if [ ! -f {quoted_script_path} ]; then exit 1; fi; . {quoted_script_path}; type __tmux_chat_notify_preexec >/dev/null 2>&1 && type __tmux_chat_notify_precmd >/dev/null 2>&1"
    );

    match Command::new(&bash_binary)
        .arg("-c")
        .arg(&probe_command)
        .env("TMUX", "tmux-chat-probe")
        .env("TMUX_CHAT_BASH_AUTO_NOTIFY_PROBE", "1")
        .output()
    {
        Ok(out) => BashRuntimeProbeResult {
            success: Some(out.status.success()),
            detail: if out.status.success() {
                "ok".to_string()
            } else {
                "failed".to_string()
            },
            bash_binary_path: Some(bash_binary),
        },
        Err(_) => BashRuntimeProbeResult {
            success: None,
            detail: "unavailable:spawn_error".to_string(),
            bash_binary_path: Some(bash_binary),
        },
    }
}

pub fn render_startup_managed_block(script_path: &Path) -> String {
    let quoted_script_path = shell_quote(&script_path.to_string_lossy());
    format!(
        "{BASH_MANAGED_BLOCK_START}\n# Managed by `host-agent install-shell-notify`; changes may be overwritten.\nif [ -f {quoted_script_path} ]; then\n  . {quoted_script_path}\nfi\n{BASH_MANAGED_BLOCK_END}\n"
    )
}

pub fn upsert_managed_block(existing: &str, managed_block: &str) -> String {
    if let Some((block_start, tail_start)) = find_any_managed_block_range(existing) {
        let mut combined = String::new();
        combined.push_str(&existing[..block_start]);
        combined.push_str(managed_block);
        combined.push_str(&existing[tail_start..]);
        return combined;
    }

    if existing.trim().is_empty() {
        managed_block.to_string()
    } else if existing.ends_with('\n') {
        format!("{existing}\n{managed_block}")
    } else {
        format!("{existing}\n\n{managed_block}")
    }
}

pub fn remove_managed_block(existing: &str) -> String {
    if let Some((block_start, tail_start)) = find_any_managed_block_range(existing) {
        let mut updated = String::new();
        updated.push_str(&existing[..block_start]);
        updated.push_str(&existing[tail_start..]);
        return updated;
    }
    existing.to_string()
}

fn render_bash_script(binary_path: &Path, min_seconds: u64) -> String {
    let binary = shell_quote(&binary_path.to_string_lossy());
    format!(
        r#"# shellcheck shell=bash
# Managed by `host-agent install-shell-notify`; changes may be overwritten.

if [[ -z "${{BASH_VERSION:-}}" ]]; then
  return 0
fi

TMUX_CHAT_NOTIFY_PROBE_MODE="${{TMUX_CHAT_BASH_AUTO_NOTIFY_PROBE:-0}}"

if [[ "${{TMUX_CHAT_NOTIFY_PROBE_MODE}}" != "1" ]]; then
  case $- in
    *i*) ;;
    *) return 0 ;;
  esac

  if [[ -z "${{TMUX:-}}" ]]; then
    return 0
  fi
fi

if [[ "${{TMUX_CHAT_BASH_AUTO_NOTIFY_LOADED:-0}}" == "1" ]]; then
  return 0
fi
TMUX_CHAT_BASH_AUTO_NOTIFY_LOADED=1

TMUX_CHAT_HOST_AGENT_BIN={binary}
TMUX_CHAT_NOTIFY_MIN_SECONDS={min_seconds}

__tmux_chat_notify_now_epoch() {{
  if [[ -n "${{EPOCHSECONDS:-}}" ]]; then
    printf '%s\n' "${{EPOCHSECONDS}}"
  else
    date +%s
  fi
}}

__tmux_chat_notify_should_ignore_command() {{
  local cmd="${{BASH_COMMAND:-}}"
  case "$cmd" in
    "" | __tmux_chat_notify_* )
      return 0
      ;;
    *'emit-bell'* )
      return 0
      ;;
  esac
  return 1
}}

__tmux_chat_notify_preexec() {{
  if [[ "${{__tmux_chat_notify_in_after:-0}}" == "1" ]]; then
    return 0
  fi
  if [[ "${{__tmux_chat_notify_should_emit:-0}}" == "1" ]]; then
    return 0
  fi
  if __tmux_chat_notify_should_ignore_command; then
    return 0
  fi

  __tmux_chat_notify_started_at="$(__tmux_chat_notify_now_epoch)"
  __tmux_chat_notify_should_emit=1
}}

__tmux_chat_notify_emit() {{
  local pane_target
  if [[ ! -x "${{TMUX_CHAT_HOST_AGENT_BIN}}" ]]; then
    return 0
  fi
  pane_target="$(tmux display-message -p '#S:#I.#P' 2>/dev/null || true)"
  if [[ -z "$pane_target" ]]; then
    return 0
  fi
  "${{TMUX_CHAT_HOST_AGENT_BIN}}" emit-bell --pane-target "$pane_target" >/dev/null 2>&1 || true
}}

__tmux_chat_notify_precmd() {{
  local exit_code=$?
  __tmux_chat_notify_in_after=1

  if [[ "${{__tmux_chat_notify_should_emit:-0}}" == "1" ]]; then
    local started_at="${{__tmux_chat_notify_started_at:-0}}"
    local now elapsed min_seconds
    now="$(__tmux_chat_notify_now_epoch)"
    elapsed=$((now - started_at))
    min_seconds="${{TMUX_CHAT_NOTIFY_MIN_SECONDS:-3}}"

    if [[ "$elapsed" -ge "$min_seconds" ]]; then
      __tmux_chat_notify_emit
    fi
  fi

  __tmux_chat_notify_should_emit=0
  __tmux_chat_notify_started_at=0
  __tmux_chat_notify_in_after=0
  return "$exit_code"
}}

__tmux_chat_notify_install_prompt_hook() {{
  local prompt_decl
  prompt_decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
  if [[ "$prompt_decl" == "declare -a"* ]]; then
    local entry
    for entry in "${{PROMPT_COMMAND[@]}}"; do
      if [[ "$entry" == "__tmux_chat_notify_precmd" ]]; then
        return 0
      fi
    done
    PROMPT_COMMAND=(__tmux_chat_notify_precmd "${{PROMPT_COMMAND[@]}}")
    return 0
  fi

  case ";${{PROMPT_COMMAND:-}};" in
    *";__tmux_chat_notify_precmd;"*) ;;
    *)
      if [[ -n "${{PROMPT_COMMAND:-}}" ]]; then
        PROMPT_COMMAND="__tmux_chat_notify_precmd;${{PROMPT_COMMAND}}"
      else
        PROMPT_COMMAND="__tmux_chat_notify_precmd"
      fi
      ;;
  esac
}}

__tmux_chat_notify_install_debug_hook() {{
  local debug_trap existing
  debug_trap="$(trap -p DEBUG 2>/dev/null || true)"
  if [[ "$debug_trap" == *"__tmux_chat_notify_preexec"* ]]; then
    return 0
  fi

  if [[ "$debug_trap" == "trap -- "* ]]; then
    existing="${{debug_trap#trap -- \'}}"
    existing="${{existing%\' DEBUG}}"
    TMUX_CHAT_NOTIFY_PREV_DEBUG_TRAP="$existing"
    trap '__tmux_chat_notify_preexec; eval "$TMUX_CHAT_NOTIFY_PREV_DEBUG_TRAP"' DEBUG
  else
    trap '__tmux_chat_notify_preexec' DEBUG
  fi
}}

__tmux_chat_notify_install_bash_preexec_hooks() {{
  if ! declare -F __bp_preexec_invoke_exec >/dev/null 2>&1; then
    return 1
  fi

  if ! declare -p preexec_functions >/dev/null 2>&1; then
    preexec_functions=()
  fi
  if ! declare -p precmd_functions >/dev/null 2>&1; then
    precmd_functions=()
  fi

  local entry
  for entry in "${{preexec_functions[@]}}"; do
    if [[ "$entry" == "__tmux_chat_notify_preexec" ]]; then
      break
    fi
  done
  if [[ "$entry" != "__tmux_chat_notify_preexec" ]]; then
    preexec_functions+=("__tmux_chat_notify_preexec")
  fi

  entry=""
  for entry in "${{precmd_functions[@]}}"; do
    if [[ "$entry" == "__tmux_chat_notify_precmd" ]]; then
      break
    fi
  done
  if [[ "$entry" != "__tmux_chat_notify_precmd" ]]; then
    precmd_functions+=("__tmux_chat_notify_precmd")
  fi
  return 0
}}

if [[ "${{TMUX_CHAT_NOTIFY_PROBE_MODE}}" == "1" ]]; then
  return 0
fi

if ! __tmux_chat_notify_install_bash_preexec_hooks; then
  __tmux_chat_notify_install_debug_hook
  __tmux_chat_notify_install_prompt_hook
fi
"#
    )
}

fn install_target_startup_paths(paths: &AgentPaths) -> Vec<PathBuf> {
    dedupe_paths(vec![
        paths.bashrc_path.clone(),
        login_startup_path_for_install(paths),
    ])
}

fn all_candidate_startup_paths(paths: &AgentPaths) -> Vec<PathBuf> {
    dedupe_paths(vec![
        paths.bashrc_path.clone(),
        paths.bash_profile_path.clone(),
        paths.bash_login_path.clone(),
        paths.profile_path.clone(),
    ])
}

fn login_startup_path_for_install(paths: &AgentPaths) -> PathBuf {
    for candidate in [
        &paths.bash_profile_path,
        &paths.bash_login_path,
        &paths.profile_path,
    ] {
        if candidate.exists() {
            return candidate.clone();
        }
    }
    paths.bash_profile_path.clone()
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut deduped = Vec::new();
    for path in paths {
        if !deduped.contains(&path) {
            deduped.push(path);
        }
    }
    deduped
}

fn find_block_range(
    existing: &str,
    start_marker: &str,
    end_marker: &str,
) -> Option<(usize, usize)> {
    let start = existing.find(start_marker)?;
    let end_rel = existing[start..].find(end_marker)?;
    let mut block_end = start + end_rel + end_marker.len();
    if existing[block_end..].starts_with('\n') {
        block_end += 1;
    }
    Some((start, block_end))
}

fn find_any_managed_block_range(existing: &str) -> Option<(usize, usize)> {
    if let Some(range) =
        find_block_range(existing, BASH_MANAGED_BLOCK_START, BASH_MANAGED_BLOCK_END)
    {
        return Some(range);
    }

    let start_suffix_pos = existing.find(BASH_MANAGED_BLOCK_START_SUFFIX)?;
    let block_start = existing[..start_suffix_pos]
        .rfind('\n')
        .map_or(0, |idx| idx + 1);
    let end_suffix_rel = existing[start_suffix_pos..].find(BASH_MANAGED_BLOCK_END_SUFFIX)?;
    let mut block_end = start_suffix_pos + end_suffix_rel + BASH_MANAGED_BLOCK_END_SUFFIX.len();
    if existing[block_end..].starts_with('\n') {
        block_end += 1;
    }
    Some((block_start, block_end))
}

fn shell_quote(raw: &str) -> String {
    let mut quoted = String::from("'");
    for ch in raw.chars() {
        if ch == '\'' {
            quoted.push_str("'\"'\"'");
        } else {
            quoted.push(ch);
        }
    }
    quoted.push('\'');
    quoted
}

fn bash_from_command_v() -> Option<PathBuf> {
    let output = Command::new("sh")
        .args(["-lc", "command -v bash 2>/dev/null || true"])
        .output()
        .ok()?;

    let stdout_lossy = String::from_utf8_lossy(&output.stdout);
    let candidate = stdout_lossy
        .lines()
        .next()
        .map(str::trim)
        .unwrap_or_default();
    if candidate.is_empty() {
        return None;
    }

    let path = PathBuf::from(candidate);
    if path.is_file() {
        Some(path)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn test_paths(base: &Path) -> AgentPaths {
        AgentPaths {
            data_dir: base.join("data"),
            runtime_dir: base.join("runtime"),
            config_path: base.join("data").join("agent.json"),
            settings_path: base.join("data").join("settings.json"),
            socket_path: base.join("runtime").join("bell.sock"),
            tmux_conf_path: base.join(".tmux.conf"),
            bashrc_path: base.join(".bashrc"),
            bash_profile_path: base.join(".bash_profile"),
            bash_login_path: base.join(".bash_login"),
            profile_path: base.join(".profile"),
            bash_auto_notify_script_path: base
                .join(".local")
                .join("lib")
                .join("tmux-chat")
                .join("bash-auto-notify.sh"),
            launchd_plist_path: base
                .join("Library")
                .join("LaunchAgents")
                .join("agent.plist"),
            launchd_log_dir: base.join("Library").join("Logs"),
            systemd_service_path: base
                .join(".config")
                .join("systemd")
                .join("user")
                .join("service"),
        }
    }

    #[test]
    fn upsert_managed_block_is_idempotent() {
        let existing = "export FOO=1\n";
        let managed = format!("{BASH_MANAGED_BLOCK_START}\nfoo\n{BASH_MANAGED_BLOCK_END}\n");
        let once = upsert_managed_block(existing, &managed);
        let twice = upsert_managed_block(&once, &managed);
        assert_eq!(once, twice);
        assert_eq!(once.matches(BASH_MANAGED_BLOCK_START).count(), 1);
        assert_eq!(once.matches(BASH_MANAGED_BLOCK_END).count(), 1);
    }

    #[test]
    fn remove_managed_block_keeps_other_content() {
        let input =
            format!("a=1\n{BASH_MANAGED_BLOCK_START}\nmanaged\n{BASH_MANAGED_BLOCK_END}\nb=2\n");
        let output = remove_managed_block(&input);
        assert!(output.contains("a=1"));
        assert!(output.contains("b=2"));
        assert!(!output.contains("managed"));
    }

    #[test]
    fn install_and_uninstall_are_safe_to_repeat() {
        let dir = tempdir().expect("tempdir");
        let paths = test_paths(dir.path());
        fs::write(&paths.profile_path, "export FOO=1\n").expect("seed profile");
        let binary_path = Path::new("/tmp/host-agent");

        let first_install =
            install_bash_auto_notify(&paths, binary_path, 3).expect("first install");
        assert_eq!(first_install.login_startup_path, paths.profile_path);
        install_bash_auto_notify(&paths, binary_path, 3).expect("second install");

        let bashrc = fs::read_to_string(&paths.bashrc_path).expect("read bashrc");
        let profile = fs::read_to_string(&paths.profile_path).expect("read profile");
        assert_eq!(bashrc.matches(BASH_MANAGED_BLOCK_START).count(), 1);
        assert_eq!(profile.matches(BASH_MANAGED_BLOCK_START).count(), 1);
        assert!(paths.bash_auto_notify_script_path.exists());
        assert!(is_bash_auto_notify_configured(&paths).expect("configured check"));
        assert_eq!(
            configured_bash_startup_files(&paths)
                .expect("configured files")
                .len(),
            2
        );

        uninstall_bash_auto_notify(&paths).expect("first uninstall");
        uninstall_bash_auto_notify(&paths).expect("second uninstall");
        let bashrc = fs::read_to_string(&paths.bashrc_path).expect("read bashrc");
        let profile = fs::read_to_string(&paths.profile_path).expect("read profile");
        assert!(!bashrc.contains(BASH_MANAGED_BLOCK_START));
        assert!(!profile.contains(BASH_MANAGED_BLOCK_START));
        assert!(!paths.bash_auto_notify_script_path.exists());
        assert!(!is_bash_auto_notify_configured(&paths).expect("configured check"));
    }

    #[test]
    fn rendered_script_supports_probe_mode_without_prompt_hooks() {
        let script = render_bash_script(Path::new("/tmp/host-agent"), 3);
        assert!(script.contains("TMUX_CHAT_NOTIFY_PROBE_MODE"));
        assert!(script.contains("TMUX_CHAT_BASH_AUTO_NOTIFY_PROBE"));
        assert!(script.contains("if [[ \"${TMUX_CHAT_NOTIFY_PROBE_MODE}\" == \"1\" ]]; then"));
        assert!(script.contains("return 0"));
    }
}
