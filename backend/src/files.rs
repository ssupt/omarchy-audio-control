//! Shared locking and atomic JSON storage. Lock names remain compatible with
//! the Bluetooth companion and the legacy helpers during migration.
use crate::protocol::{Failure, Result};
use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub struct FileLock {
    _file: File,
}
impl FileLock {
    pub fn descriptor(&self) -> std::os::fd::RawFd {
        self._file.as_raw_fd()
    }
    pub async fn mutation() -> Result<Self> {
        Self::runtime("omarchy-audio-mutation.lock").await
    }
    pub async fn settings() -> Result<Self> {
        Self::runtime("omarchy-audio-settings.lock").await
    }
    async fn runtime(name: &'static str) -> Result<Self> {
        let runtime = std::env::var_os("AUDIO_CONTROL_PRIVATE_RUNTIME_DIR")
            .or_else(|| std::env::var_os("XDG_RUNTIME_DIR"))
            .ok_or_else(|| Failure::new("unsafe_path", "Private audio runtime is unavailable"))?;
        let runtime = PathBuf::from(runtime);
        let metadata = fs::symlink_metadata(&runtime)?;
        // SAFETY: geteuid has no preconditions.
        if !runtime.is_absolute()
            || !metadata.is_dir()
            || metadata.mode() & 0o022 != 0
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(Failure::new("unsafe_path", "Audio runtime is not private"));
        }
        tokio::task::spawn_blocking(move || Self::acquire(&runtime.join(name)))
            .await
            .map_err(|_| Failure::new("internal_error", "Could not acquire audio lock"))?
    }
    pub fn acquire(path: &Path) -> Result<Self> {
        let path = resolve_parent(path)?;
        let parent = path
            .parent()
            .ok_or_else(|| Failure::new("unsafe_path", "Lock needs a parent directory"))?;
        let directory = fs::symlink_metadata(parent)?;
        if !directory.is_dir() || (directory.mode() & 0o022 != 0 && directory.mode() & 0o1000 == 0)
        {
            return Err(Failure::new(
                "unsafe_path",
                "Lock directory is writable by other users",
            ));
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&path)?;
        let metadata = file.metadata()?;
        // SAFETY: geteuid has no memory/ownership preconditions.
        let uid = unsafe { libc::geteuid() };
        let linked = fs::symlink_metadata(&path)?;
        if !metadata.is_file()
            || metadata.uid() != uid
            || metadata.nlink() != 1
            || linked.file_type().is_symlink()
            || linked.ino() != metadata.ino()
            || linked.dev() != metadata.dev()
        {
            return Err(Failure::new(
                "unsafe_path",
                "Lock is not a private regular file",
            ));
        }
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            // SAFETY: file owns this valid descriptor throughout the call.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::WouldBlock {
                return Err(error.into());
            }
            if Instant::now() >= deadline {
                return Err(Failure::new("busy", "Audio configuration is busy"));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        Ok(Self { _file: file })
    }
}

// Dotfiles managers commonly symlink the configuration directory. Resolve that
// directory once while leaving the leaf untouched for O_NOFOLLOW checks.
pub fn resolve_parent(path: &Path) -> Result<PathBuf> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| Failure::new("unsafe_path", "Path needs a parent directory"))?;
    let name = path
        .file_name()
        .ok_or_else(|| Failure::new("unsafe_path", "Path needs a file name"))?;
    Ok(fs::canonicalize(parent)?.join(name))
}

pub fn read_json(path: &Path, limit: usize) -> Result<Option<Value>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(Failure::new(
            "invalid_store",
            "Audio configuration is not a regular file",
        ));
    }
    if metadata.len() > limit as u64 {
        return Err(Failure::new(
            "invalid_store",
            "Audio configuration is too large",
        ));
    }
    let mut bytes = Vec::new();
    file.take((limit + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(Failure::new(
            "invalid_store",
            "Audio configuration is too large",
        ));
    }
    if bytes.is_empty() {
        return Ok(None);
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| {
        Failure::new(
            "invalid_store",
            "Audio configuration contains invalid JSON; refusing to overwrite it",
        )
    })?;
    if !value.is_object() {
        return Err(Failure::new(
            "invalid_store",
            "Audio configuration must be an object",
        ));
    }
    if value.get("version").is_some_and(|v| v != 1) {
        return Err(Failure::new(
            "unsupported_schema",
            "Audio configuration uses an unsupported version; refusing to overwrite it",
        ));
    }
    Ok(Some(value))
}

pub fn write_json(path: &Path, value: &Value, limit: usize) -> Result<()> {
    let mut data = serde_json::to_vec(value)
        .map_err(|_| Failure::new("invalid_store", "Could not encode audio configuration"))?;
    data.push(b'\n');
    if data.len() > limit {
        return Err(Failure::new(
            "invalid_store",
            "Audio configuration is too large",
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| Failure::new("unsafe_path", "Configuration needs a parent directory"))?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    temporary.write_all(&data)?;
    temporary.as_file().sync_all()?;
    // Check again after writing the temporary file, while the shared lock is held.
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(Failure::new(
                "unsafe_path",
                "Configuration path was replaced",
            ));
        }
    }
    temporary
        .persist(path)
        .map_err(|error| Failure::from(error.error))?;
    File::open(parent)?.sync_all().map_err(|_| {
        Failure::unknown("Configuration was saved but directory durability could not be confirmed")
    })?;
    Ok(())
}

pub fn suffixed(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn linked_directories_do_not_allow_unsafe_lock_files() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("real");
        fs::create_dir(&target).unwrap();
        let link = directory.path().join("linked");
        symlink(&target, &link).unwrap();
        let lock = link.join("lock");
        let other = target.join("other");
        symlink(&other, &lock).unwrap();
        assert!(FileLock::acquire(&lock).is_err());
        assert!(!other.exists());
        fs::remove_file(&lock).unwrap();
        fs::write(&other, b"untouched").unwrap();
        fs::hard_link(&other, &lock).unwrap();
        assert!(FileLock::acquire(&lock).is_err());
        assert_eq!(fs::read(&other).unwrap(), b"untouched");
        fs::remove_file(&lock).unwrap();
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&lock)
                .status()
                .unwrap()
                .success()
        );
        assert!(FileLock::acquire(&lock).is_err());
    }
}
