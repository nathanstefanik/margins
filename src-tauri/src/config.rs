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

        Ok(Self { data_dir, stored })
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn library_root(&self) -> PathBuf {
        self.stored
            .library_root
            .clone()
            .filter(|p| p.exists())
            .unwrap_or_else(|| self.data_dir.join("library"))
    }

    pub fn set_library_root(&mut self, path: PathBuf) -> Result<(), ConfigError> {
        fs::create_dir_all(&path)?;
        self.stored.library_root = Some(path);
        self.persist()
    }

    fn persist(&self) -> Result<(), ConfigError> {
        let config_path = self.data_dir.join("config.json");
        let raw = serde_json::to_string_pretty(&self.stored)?;
        fs::write(config_path, raw)?;
        Ok(())
    }
}

fn resolve_data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("MARGINALIA_DATA_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }

    if let Ok(dir) = std::env::var("MARGINALIA_LIBRARY_ROOT") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }

    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("marginalia")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_library_root_persists_and_reloads() {
        let tmp = tempfile::tempdir().unwrap();
        let data_dir = tmp.path().join("data");
        let library_root = tmp.path().join("external-lib");

        // Isolate from the developer's real data dir.
        std::env::set_var("MARGINALIA_DATA_DIR", &data_dir);
        std::env::remove_var("MARGINALIA_LIBRARY_ROOT");

        let mut config = AppConfig::load().unwrap();
        assert_eq!(config.data_dir(), data_dir.as_path());
        assert_eq!(config.library_root(), data_dir.join("library"));

        config.set_library_root(library_root.clone()).unwrap();
        assert_eq!(config.library_root(), library_root);
        assert!(data_dir.join("config.json").exists());

        let reloaded = AppConfig::load().unwrap();
        assert_eq!(reloaded.library_root(), library_root);

        std::env::remove_var("MARGINALIA_DATA_DIR");
    }
}
