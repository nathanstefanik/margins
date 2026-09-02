use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredConfig {
    #[serde(default)]
    pub library_root: Option<PathBuf>,
}

pub struct AppConfig {
    data_dir: PathBuf,
    stored: StoredConfig,
    library_root: PathBuf,
}

impl AppConfig {
    pub fn load() -> Result<Self, ConfigError> {
        let data_dir = resolve_data_dir();
        fs::create_dir_all(&data_dir)?;

        let config_path = data_dir.join("config.json");
        let stored = if config_path.exists() {
            let raw = fs::read_to_string(&config_path)?;
            serde_json::from_str(&raw)?
        } else {
            StoredConfig { library_root: None }
        };

        let library_root = resolve_library_root(&data_dir, stored.library_root.clone());

        Ok(Self {
            data_dir,
            stored,
            library_root,
        })
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn library_root(&self) -> PathBuf {
        self.library_root.clone()
    }

    pub fn set_library_root(&mut self, path: PathBuf) -> Result<(), ConfigError> {
        fs::create_dir_all(&path)?;
        let previous = self.stored.library_root.clone();
        self.stored.library_root = Some(path.clone());
        if let Err(error) = self.persist() {
            self.stored.library_root = previous;
            return Err(error);
        }
        self.library_root = path;
        Ok(())
    }

    fn persist(&self) -> Result<(), ConfigError> {
        let config_path = self.data_dir.join("config.json");
        let raw = serde_json::to_string_pretty(&self.stored)?;
        fs::write(config_path, raw)?;
        Ok(())
    }
}

fn resolve_data_dir() -> PathBuf {
    env_path("MARGINS_DATA_DIR").unwrap_or_else(|| {
        dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("margins")
    })
}

fn resolve_library_root(data_dir: &Path, configured: Option<PathBuf>) -> PathBuf {
    env_path("MARGINS_LIBRARY_ROOT")
        .or(configured)
        .unwrap_or_else(|| data_dir.join("library"))
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn set_library_root_persists_and_reloads() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let data_dir = tmp.path().join("data");
        let library_root = tmp.path().join("external-lib");

        // Isolate from the developer's real data dir.
        std::env::set_var("MARGINS_DATA_DIR", &data_dir);
        std::env::remove_var("MARGINS_LIBRARY_ROOT");

        let mut config = AppConfig::load().unwrap();
        assert_eq!(config.data_dir(), data_dir.as_path());
        assert_eq!(config.library_root(), data_dir.join("library"));

        config.set_library_root(library_root.clone()).unwrap();
        assert_eq!(config.library_root(), library_root);
        assert!(data_dir.join("config.json").exists());

        let reloaded = AppConfig::load().unwrap();
        assert_eq!(reloaded.library_root(), library_root);

        std::env::remove_var("MARGINS_DATA_DIR");
    }

    #[test]
    fn library_root_environment_variable_points_at_the_selected_directory() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let data_dir = tmp.path().join("data");
        let library_root = tmp.path().join("synced-library");

        std::env::set_var("MARGINS_DATA_DIR", &data_dir);
        std::env::set_var("MARGINS_LIBRARY_ROOT", &library_root);

        let config = AppConfig::load().unwrap();
        assert_eq!(config.data_dir(), data_dir.as_path());
        assert_eq!(config.library_root(), library_root);
        assert!(!data_dir.join("library").exists());

        std::env::remove_var("MARGINS_DATA_DIR");
        std::env::remove_var("MARGINS_LIBRARY_ROOT");
    }
}
