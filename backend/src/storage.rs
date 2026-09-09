use crate::files::{self, FileLock};
use crate::protocol::{Failure, Request, Result};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Settings,
    Preferences,
    Rules,
    Scenes,
}
impl Kind {
    pub const ALL: [Self; 4] = [Self::Settings, Self::Preferences, Self::Rules, Self::Scenes];
    pub fn key(self) -> &'static str {
        match self {
            Self::Settings => "settings",
            Self::Preferences => "preferences",
            Self::Rules => "rules",
            Self::Scenes => "scenes",
        }
    }
    pub fn filename(self) -> &'static str {
        match self {
            Self::Settings => "audio-control.json",
            Self::Preferences => "audio-preferences.json",
            Self::Rules => "audio-rules.json",
            Self::Scenes => "audio-scenes.json",
        }
    }
    fn override_variable(self) -> &'static str {
        match self {
            Self::Settings => "OMARCHY_AUDIO_CONTROL_FILE",
            Self::Preferences => "OMARCHY_AUDIO_PREFERENCES_FILE",
            Self::Rules => "OMARCHY_AUDIO_RULES_FILE",
            Self::Scenes => "OMARCHY_AUDIO_SCENES_FILE",
        }
    }
    fn limit(self) -> usize {
        if matches!(self, Self::Scenes) {
            2097152
        } else {
            1048576
        }
    }
}

#[derive(Clone)]
pub struct Storage {
    pub directory: PathBuf,
}
impl Storage {
    pub fn from_environment() -> Result<Self> {
        let directory = std::env::var_os("XDG_CONFIG_HOME")
            .filter(|p| !p.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")))
            .ok_or_else(|| {
                Failure::new(
                    "configuration_error",
                    "No configuration directory is available",
                )
            })?;
        if !directory.is_absolute() || directory.parent().is_none() {
            return Err(Failure::new(
                "configuration_error",
                "Configuration directory must be an absolute non-root path",
            ));
        }
        Ok(Self {
            directory: directory.join("omarchy"),
        })
    }
    pub fn path(&self, kind: Kind) -> Result<PathBuf> {
        let path = std::env::var_os(kind.override_variable())
            .map(PathBuf::from)
            .unwrap_or_else(|| self.directory.join(kind.filename()));
        if !path.is_absolute() {
            return Err(Failure::new(
                "unsafe_path",
                "Audio store path must be absolute",
            ));
        }
        Ok(path)
    }
    pub fn read(&self, kind: Kind) -> Result<Value> {
        let raw = files::read_json(&self.path(kind)?, kind.limit())?.unwrap_or_else(|| json!({}));
        Ok(normalize(kind, &raw))
    }
    pub fn update(
        &self,
        kind: Kind,
        change: impl FnOnce(&mut Value) -> Result<()>,
    ) -> Result<Value> {
        let path = self.path(kind)?;
        std::fs::create_dir_all(
            path.parent()
                .ok_or_else(|| Failure::new("unsafe_path", "Missing store directory"))?,
        )?;
        // Keep the lock, read and atomic replacement on the same target even if
        // a dotfiles manager retargets the directory symlink during the edit.
        let path = files::resolve_parent(&path)?;
        let _lock = FileLock::acquire(&files::suffixed(&path, ".lock"))?;
        let raw = files::read_json(&path, kind.limit())?.unwrap_or_else(|| json!({}));
        let mut value = normalize(kind, &raw);
        change(&mut value)?;
        files::write_json(&path, &value, kind.limit())?;
        Ok(value)
    }
    pub fn handle(&self, request: &Request) -> Result<Option<Value>> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Read {
            store: Kind,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Setting {
            key: String,
            value: bool,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Default {
            direction: String,
            name: String,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Profile {
            address: String,
            profile: String,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Rule {
            app: String,
            direction: String,
            target: String,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct DeleteRule {
            app: String,
            direction: String,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Alias {
            node: String,
            label: String,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Flag {
            node: String,
            flag: String,
            value: bool,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct SaveScene {
            name: String,
            scene: Value,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct DeleteScene {
            name: String,
        }
        let value = match request.method.as_str() {
            "store.read" => self.read(request.params::<Read>()?.store)?,
            "settings.set" => {
                let params = request.params::<Setting>()?;
                if !["outputOverdrive", "captureNotifications"].contains(&params.key.as_str()) {
                    return Err(invalid());
                }
                self.update(Kind::Settings, |store| {
                    store[&params.key] = json!(params.value);
                    Ok(())
                })?
            }
            "preferences.default" => {
                let params = request.params::<Default>()?;
                require_direction(&params.direction, false)?;
                require_identifier(&params.name, 160)?;
                self.update(Kind::Preferences, |store| {
                    store["defaults"][&params.direction] = json!(params.name);
                    Ok(())
                })?
            }
            "preferences.profile" => {
                let params = request.params::<Profile>()?;
                let address = bluetooth_address(&params.address);
                require_identifier(&params.profile, 160)?;
                if address.len() != 12 {
                    return Err(invalid());
                }
                self.update(Kind::Preferences, |store| {
                    store["bluetoothProfiles"][address] = json!(params.profile);
                    Ok(())
                })?
            }
            "rules.set_app" => {
                let params = request.params::<Rule>()?;
                let app = label(&json!(params.app), 120).to_ascii_lowercase();
                if app.is_empty() {
                    return Err(invalid());
                }
                require_direction(&params.direction, true)?;
                require_identifier(&params.target, 160)?;
                self.update(Kind::Rules, |store| {
                    let rules = store["appRules"].as_array_mut().unwrap();
                    rules.retain(|r| r["app"] != app || r["direction"] != params.direction);
                    rules.push(
                        json!({"app": app, "direction": params.direction, "target": params.target}),
                    );
                    keep_last(rules, 64);
                    Ok(())
                })?
            }
            "rules.delete_app" => {
                let params = request.params::<DeleteRule>()?;
                let app = label(&json!(params.app), 120).to_ascii_lowercase();
                if app.is_empty() {
                    return Err(invalid());
                }
                require_direction(&params.direction, true)?;
                self.update(Kind::Rules, |store| {
                    store["appRules"]
                        .as_array_mut()
                        .unwrap()
                        .retain(|r| r["app"] != app || r["direction"] != params.direction);
                    Ok(())
                })?
            }
            "devices.alias" => {
                let params = request.params::<Alias>()?;
                require_identifier(&params.node, 160)?;
                let label = label(&json!(params.label), 80);
                self.update(Kind::Rules, |store| {
                    let aliases = store["devices"]["aliases"].as_object_mut().unwrap();
                    aliases.shift_remove(&params.node);
                    if !label.is_empty() {
                        aliases.insert(params.node, json!(label));
                    }
                    while aliases.len() > 128 {
                        let key = aliases.keys().next().unwrap().clone();
                        aliases.shift_remove(&key);
                    }
                    Ok(())
                })?
            }
            "devices.flag" => {
                let params = request.params::<Flag>()?;
                require_identifier(&params.node, 160)?;
                let key = match params.flag.as_str() {
                    "favorite" => "favorites",
                    "hidden" => "hidden",
                    _ => return Err(invalid()),
                };
                self.update(Kind::Rules, |store| {
                    let values = store["devices"][key].as_array_mut().unwrap();
                    values.retain(|v| v != &params.node);
                    if params.value {
                        values.push(json!(params.node));
                    }
                    keep_last(values, 64);
                    Ok(())
                })?
            }
            "scenes.save" => {
                let params = request.params::<SaveScene>()?;
                if !params.scene.is_object() {
                    return Err(invalid());
                }
                let name = label(&json!(params.name), 48);
                if name.is_empty() {
                    return Err(invalid());
                }
                let mut scene = params.scene;
                scene["name"] = json!(name);
                let scene = normalize_scene(&scene).ok_or_else(invalid)?;
                self.update(Kind::Scenes, |store| {
                    let scenes = store["scenes"].as_array_mut().unwrap();
                    scenes.retain(|s| s["name"] != name);
                    scenes.push(scene);
                    keep_last(scenes, 24);
                    Ok(())
                })?
            }
            "scenes.delete" => {
                let params = request.params::<DeleteScene>()?;
                let name = label(&json!(params.name), 48);
                if name.is_empty() {
                    return Err(invalid());
                }
                self.update(Kind::Scenes, |store| {
                    store["scenes"]
                        .as_array_mut()
                        .unwrap()
                        .retain(|s| s["name"] != name);
                    Ok(())
                })?
            }
            _ => return Ok(None),
        };
        Ok(Some(value))
    }
}

fn invalid() -> Failure {
    Failure::new("invalid_params", "Invalid audio configuration change")
}
fn forbidden(ch: char) -> bool {
    matches!(ch, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{200e}' | '\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
}
pub fn identifier(value: &Value, maximum: usize) -> String {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.chars().count() <= maximum && !s.chars().any(forbidden))
        .unwrap_or("")
        .into()
}
pub fn require_identifier(value: &str, maximum: usize) -> Result<()> {
    if identifier(&json!(value), maximum).is_empty() {
        Err(invalid())
    } else {
        Ok(())
    }
}
pub fn label(value: &Value, maximum: usize) -> String {
    let text = match value {
        Value::Null | Value::Bool(false) => String::new(),
        Value::String(s) => s.clone(),
        value => value.to_string(),
    };
    let text: String = text
        .chars()
        .map(|c| if forbidden(c) { ' ' } else { c })
        .collect();
    text.split(' ')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(maximum)
        .collect()
}
pub fn bluetooth_address(value: &str) -> String {
    value
        .chars()
        .filter(char::is_ascii_hexdigit)
        .collect::<String>()
        .to_ascii_lowercase()
}
fn require_direction(value: &str, stream: bool) -> Result<()> {
    if (if stream {
        ["playback", "recording"]
    } else {
        ["output", "input"]
    })
    .contains(&value)
    {
        Ok(())
    } else {
        Err(invalid())
    }
}
fn array(value: &Value, max: usize) -> impl Iterator<Item = &Value> {
    value.as_array().into_iter().flatten().take(max)
}
fn number(value: &Value, fallback: f64, min: f64, max: f64) -> f64 {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
        .filter(|v| v.is_finite())
        .unwrap_or(fallback)
        .clamp(min, max)
}
fn keep_last(values: &mut Vec<Value>, maximum: usize) {
    if values.len() > maximum {
        values.drain(..values.len() - maximum);
    }
}
fn unique(values: impl Iterator<Item = (String, Value)>, max: usize) -> Vec<Value> {
    let mut seen = BTreeSet::new();
    values
        .filter_map(|(key, value)| if seen.insert(key) { Some(value) } else { None })
        .take(max)
        .collect()
}
fn strings(value: &Value, max: usize) -> Value {
    json!(unique(
        array(value, 256).filter_map(|value| {
            let name = identifier(value, 160);
            if name.is_empty() {
                None
            } else {
                Some((name.clone(), json!(name)))
            }
        }),
        max
    ))
}

pub fn normalize(kind: Kind, raw: &Value) -> Value {
    match kind {
        Kind::Settings => {
            let mut value = raw.clone();
            value["version"] = json!(1);
            value["outputOverdrive"] = json!(raw["outputOverdrive"] == true);
            value["captureNotifications"] = json!(raw["captureNotifications"] != false);
            value
        }
        Kind::Preferences => {
            let mut profiles = Map::new();
            for (key, value) in raw["bluetoothProfiles"]
                .as_object()
                .into_iter()
                .flatten()
                .take(512)
            {
                let address = bluetooth_address(key);
                let profile = identifier(value, 160);
                if address.len() == 12 && !profile.is_empty() && profiles.len() < 128 {
                    profiles.entry(address).or_insert(json!(profile));
                }
            }
            json!({"version": 1, "defaults": {"output": identifier(&raw["defaults"]["output"], 160), "input": identifier(&raw["defaults"]["input"], 160)}, "bluetoothProfiles": profiles})
        }
        Kind::Rules => {
            let rules = unique(
                array(&raw["appRules"], 256).filter_map(|rule| {
                    let app = label(&rule["app"], 120).to_ascii_lowercase();
                    let target = identifier(&rule["target"], 160);
                    let direction = rule["direction"].as_str().unwrap_or("");
                    if app.is_empty()
                        || target.is_empty()
                        || require_direction(direction, true).is_err()
                    {
                        return None;
                    }
                    Some((
                        format!("{direction}:{app}"),
                        json!({"app": app, "direction": direction, "target": target}),
                    ))
                }),
                64,
            );
            let mut aliases = Map::new();
            for (key, value) in raw["devices"]["aliases"]
                .as_object()
                .into_iter()
                .flatten()
                .take(256)
            {
                let node = identifier(&json!(key), 160);
                let label = label(value, 80);
                if !node.is_empty() && !label.is_empty() && aliases.len() < 128 {
                    aliases.entry(node).or_insert(json!(label));
                }
            }
            json!({"version": 1, "appRules": rules, "outputGroups": normalize_groups(&raw["outputGroups"]),
                "devices": {"aliases": aliases, "favorites": strings(&raw["devices"]["favorites"],64), "hidden": strings(&raw["devices"]["hidden"],64)}})
        }
        Kind::Scenes => {
            json!({"version": 1, "scenes": unique(array(&raw["scenes"], 96).filter_map(normalize_scene)
            .map(|scene| (scene["name"].as_str().unwrap().into(), scene)), 24)})
        }
    }
}

pub fn group_id(value: &str) -> bool {
    value.len() == 16
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn group_sink(value: &str) -> bool {
    value
        .strip_prefix("omarchy_audio_group_")
        .is_some_and(group_id)
}
pub fn group_member(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && !group_sink(value)
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}
fn normalize_groups(raw: &Value) -> Vec<Value> {
    let mut ids = BTreeSet::new();
    let mut names = BTreeSet::new();
    let mut combinations = BTreeSet::new();
    array(raw, 64)
        .filter_map(|group| {
            let id = group["id"].as_str()?;
            let name = label(&group["name"], 48);
            let sink = format!("omarchy_audio_group_{id}");
            let members: BTreeSet<_> = array(&group["members"], 32)
                .filter_map(Value::as_str)
                .filter(|v| group_member(v))
                .map(str::to_owned)
                .collect();
            if !group_id(id)
                || name.is_empty()
                || group["sink"] != sink
                || !(2..=8).contains(&members.len())
                || ids.contains(id)
                || names.contains(&name.to_ascii_lowercase())
                || combinations.contains(&members)
            {
                return None;
            }
            ids.insert(id.to_owned());
            names.insert(name.to_ascii_lowercase());
            combinations.insert(members.clone());
            Some(json!({"id": id, "name": name, "sink": sink, "members": members}))
        })
        .take(16)
        .collect()
}

pub fn normalize_scene(raw: &Value) -> Option<Value> {
    if !raw.is_object() {
        return None;
    }
    let name = label(&raw["name"], 48);
    if name.is_empty() {
        return None;
    }
    let devices = unique(array(&raw["devices"], 256).filter_map(|device| {
        let name = identifier(&device["name"], 160); let direction = device["direction"].as_str().unwrap_or("");
        if name.is_empty() || require_direction(direction, false).is_err() { return None; }
        Some((format!("{direction}:{name}"), json!({"name": name, "direction": direction,
            "volume": number(&device["volume"], 1.0, 0.0, 1.5), "muted": direction == "input" && device["muted"] == true,
            "balance": number(&device["balance"], 0.0, -1.0, 1.0)})))
    }), 64);
    let ports = unique(
        array(&raw["ports"], 256).filter_map(|port| {
            let endpoint = identifier(&port["endpoint"], 160);
            let value = identifier(&port["value"], 160);
            let direction = port["direction"].as_str().unwrap_or("");
            if endpoint.is_empty()
                || value.is_empty()
                || require_direction(direction, false).is_err()
            {
                return None;
            }
            Some((
                format!("{direction}:{endpoint}"),
                json!({"endpoint":endpoint,"value":value,"direction":direction}),
            ))
        }),
        64,
    );
    let profiles = unique(
        array(&raw["profiles"], 256).filter_map(|profile| {
            let card = identifier(&profile["card"], 160);
            let profile = identifier(&profile["profile"], 160);
            if card.is_empty() || profile.is_empty() || profile == "off" {
                return None;
            }
            Some((card.clone(), json!({"card":card,"profile":profile})))
        }),
        64,
    );
    Some(json!({"name":name,"savedAt":label(&raw["savedAt"],32),
        "defaults":{"output":identifier(&raw["defaults"]["output"],160),"input":identifier(&raw["defaults"]["input"],160)},
        "devices":devices,"ports":ports,"profiles":profiles}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scenes_preserve_microphone_privacy_and_cannot_power_off_outputs() {
        let value = normalize_scene(&json!({"name":"Desk", "devices":[
            {"name":"speaker","direction":"output","muted":true,"volume":9},
            {"name":"mic","direction":"input","muted":true}],
            "profiles":[{"card":"test","profile":"off"}]}))
        .unwrap();
        assert_eq!(value["devices"][0]["muted"], false);
        assert_eq!(value["devices"][0]["volume"], 1.5);
        assert_eq!(value["devices"][1]["muted"], true);
        assert_eq!(value["profiles"], json!([]));
    }
    #[test]
    fn identifiers_are_never_silently_renamed() {
        assert_eq!(identifier(&json!("  exact name  "), 160), "  exact name  ");
        assert_eq!(identifier(&json!("spoof\u{202e}name"), 160), "");
        assert_eq!(label(&json!("\n Display   Name \t"), 80), "Display Name");
    }
    #[test]
    fn invalid_or_future_configuration_is_not_overwritten() {
        let directory = tempfile::tempdir().unwrap();
        let storage = Storage {
            directory: directory.path().into(),
        };
        let path = directory.path().join(Kind::Rules.filename());
        for original in ["{broken", "{\"version\":2}", "{} {}"] {
            std::fs::write(&path, original).unwrap();
            assert!(storage.update(Kind::Rules, |_| Ok(())).is_err());
            assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
        }
    }
    #[test]
    fn configuration_directory_symlinks_preserve_the_target_and_lock() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        use std::process::Command;
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("dotfiles");
        std::fs::create_dir(&target).unwrap();
        let link = directory.path().join("omarchy");
        symlink(&target, &link).unwrap();
        let storage = Storage {
            directory: link.clone(),
        };
        let path = target.join(Kind::Settings.filename());
        std::fs::write(&path, "{\"version\":1,\"custom\":42}").unwrap();
        storage
            .update(Kind::Settings, |value| {
                value["outputOverdrive"] = json!(true);
                Ok(())
            })
            .unwrap();
        assert!(link.is_symlink());
        let value = files::read_json(&path, 1048576).unwrap().unwrap();
        assert_eq!(value["custom"], 42);
        assert_eq!(value["outputOverdrive"], true);
        // Helpers and Rust must lock the same inode through either spelling.
        let lock = files::suffixed(&link.join(Kind::Settings.filename()), ".lock");
        let guard = FileLock::acquire(&lock).unwrap();
        let common =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/.audio-common");
        let acquire = || {
            Command::new("bash")
                .args([
                    "-c",
                    "source \"$1\"; audio_open_lock_path \"$2\" 9 busy 0",
                    "_",
                ])
                .arg(&common)
                .arg(files::suffixed(&path, ".lock"))
                .output()
                .unwrap()
        };
        assert!(!acquire().status.success());
        drop(guard);
        assert!(acquire().status.success());
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(storage.update(Kind::Settings, |_| Ok(())).is_err());
        assert_eq!(files::read_json(&path, 1048576).unwrap().unwrap(), value);
    }
    #[test]
    fn configuration_edit_stays_on_the_locked_directory() {
        use std::os::unix::fs::symlink;
        let directory = tempfile::tempdir().unwrap();
        let original = directory.path().join("original");
        let replacement = directory.path().join("replacement");
        let link = directory.path().join("omarchy");
        std::fs::create_dir(&original).unwrap();
        std::fs::create_dir(&replacement).unwrap();
        symlink(&original, &link).unwrap();
        let storage = Storage {
            directory: link.clone(),
        };
        storage
            .update(Kind::Settings, |value| {
                std::fs::remove_file(&link).unwrap();
                symlink(&replacement, &link).unwrap();
                value["outputOverdrive"] = json!(true);
                Ok(())
            })
            .unwrap();
        assert!(original.join(Kind::Settings.filename()).is_file());
        assert!(!replacement.join(Kind::Settings.filename()).exists());
    }
    #[test]
    fn configuration_replacement_is_private_and_rejects_symlinks() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let directory = tempfile::tempdir().unwrap();
        let storage = Storage {
            directory: directory.path().into(),
        };
        let path = directory.path().join(Kind::Settings.filename());
        storage
            .update(Kind::Settings, |value| {
                value["outputOverdrive"] = json!(true);
                Ok(())
            })
            .unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        std::fs::remove_file(&path).unwrap();
        symlink(directory.path().join("other"), &path).unwrap();
        assert!(storage.update(Kind::Settings, |_| Ok(())).is_err());
        assert!(!directory.path().join("other").exists());
    }
}
