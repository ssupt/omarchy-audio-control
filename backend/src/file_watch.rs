//! Watches parent directories so atomic replacement does not detach a store's
//! watch. Events are coalesced; consumers always reread the complete documents.
use std::collections::BTreeSet;
use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use tokio::io::unix::AsyncFd;

pub struct Watcher {
    fd: AsyncFd<OwnedFd>,
    names: BTreeSet<Vec<u8>>,
}
impl Watcher {
    pub fn new(paths: &[PathBuf]) -> io::Result<Self> {
        // SAFETY: inotify_init1 returns a fresh descriptor which we own exactly once.
        let raw = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: raw was successfully allocated above and has no other owner.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let mut parents = BTreeSet::new();
        let mut names = BTreeSet::new();
        for path in paths {
            let parent = path
                .parent()
                .ok_or_else(|| io::Error::other("Missing store parent"))?;
            std::fs::create_dir_all(parent)?;
            parents.insert(parent.to_path_buf());
            if let Some(name) = path.file_name() {
                names.insert(name.as_bytes().to_vec());
            }
        }
        for parent in parents {
            let path = CString::new(parent.as_os_str().as_bytes())?;
            // SAFETY: path is NUL-terminated and fd stays owned for the watch lifetime.
            let result = unsafe {
                libc::inotify_add_watch(
                    fd.as_raw_fd(),
                    path.as_ptr(),
                    libc::IN_CLOSE_WRITE
                        | libc::IN_MOVED_TO
                        | libc::IN_DELETE
                        | libc::IN_CREATE
                        | libc::IN_DELETE_SELF
                        | libc::IN_MOVE_SELF,
                )
            };
            if result < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(Self {
            fd: AsyncFd::new(fd)?,
            names,
        })
    }
    pub async fn changed(&self) -> io::Result<()> {
        let mut buffer = [0u8; 16384];
        loop {
            let mut ready = self.fd.readable().await?;
            let count = match ready.try_io(|fd| {
                // SAFETY: buffer points to a writable allocation of the supplied length.
                let count = unsafe {
                    libc::read(
                        fd.get_ref().as_raw_fd(),
                        buffer.as_mut_ptr().cast(),
                        buffer.len(),
                    )
                };
                if count < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(count as usize)
                }
            }) {
                Ok(result) => result?,
                Err(_) => continue,
            };
            let mut offset = 0;
            let mut changed = false;
            while offset + 16 <= count {
                let mask = u32::from_ne_bytes(buffer[offset + 4..offset + 8].try_into().unwrap());
                let length =
                    u32::from_ne_bytes(buffer[offset + 12..offset + 16].try_into().unwrap())
                        as usize;
                if offset + 16 + length > count {
                    return Err(io::Error::other("Truncated inotify event"));
                }
                if mask & (libc::IN_IGNORED | libc::IN_DELETE_SELF | libc::IN_MOVE_SELF) != 0 {
                    return Err(io::Error::other(
                        "Store directory changed; watches must be rebuilt",
                    ));
                }
                let name = &buffer[offset + 16..offset + 16 + length];
                let name = &name[..name.iter().position(|c| *c == 0).unwrap_or(name.len())];
                changed |= mask & libc::IN_Q_OVERFLOW != 0 || self.names.contains(name);
                offset += 16 + length;
            }
            if changed {
                return Ok(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn follows_atomic_replacements() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let watcher = Watcher::new(std::slice::from_ref(&path)).unwrap();
        for contents in ["one", "two"] {
            let temp = dir.path().join("temporary");
            std::fs::write(&temp, contents).unwrap();
            std::fs::rename(&temp, &path).unwrap();
            tokio::time::timeout(std::time::Duration::from_secs(1), watcher.changed())
                .await
                .unwrap()
                .unwrap();
        }
    }
}
