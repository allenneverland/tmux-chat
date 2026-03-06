use std::{
    fs,
    path::{Path, PathBuf},
};

pub const BASH_MANAGED_BLOCK_START: &str = "# >>> TMUX-CHAT BASH AUTO-NOTIFY START >>>";
pub const BASH_MANAGED_BLOCK_START_SUFFIX: &str = "BASH AUTO-NOTIFY START >>>";

pub fn detect_warnings() -> Vec<String> {
    let mut warnings = Vec::new();
    let Some(home) = dirs::home_dir() else {
        return warnings;
    };

    for path in startup_paths(&home) {
        if !path.exists() {
            continue;
        }
        match fs::read_to_string(&path) {
            Ok(content) => {
                if content.contains(BASH_MANAGED_BLOCK_START)
                    || content.contains(BASH_MANAGED_BLOCK_START_SUFFIX)
                {
                    warnings.push(format!(
                        "legacy_bash_startup_block_present:{}",
                        path.display()
                    ));
                }
            }
            Err(err) => warnings.push(format!(
                "legacy_bash_startup_probe_failed:{}:{}",
                path.display(),
                err
            )),
        }
    }

    let script_path = home
        .join(".local")
        .join("lib")
        .join("tmux-chat")
        .join("bash-auto-notify.sh");
    if script_path.exists() {
        warnings.push(format!(
            "legacy_bash_script_present:{}",
            script_path.display()
        ));
    }

    warnings
}

fn startup_paths(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".bashrc"),
        home.join(".bash_profile"),
        home.join(".bash_login"),
        home.join(".profile"),
    ]
}
