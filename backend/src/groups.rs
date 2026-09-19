//! Output-group transactions. Combine sinks belong to the server, not this process.
use crate::protocol::{Failure, Result};
use crate::{
    native,
    pulse::Session,
    storage::{self, Kind, Storage},
};
use libpulse_binding::context::introspect::SinkInfo;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    io::Read,
    time::{Duration, Instant},
};

const OWNER: &str = "ssupt.audio-control";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Group {
    pub id: String,
    pub name: String,
    pub sink: String,
    pub members: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Edit {
    pub generation: String,
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub members: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Delete {
    pub generation: String,
    pub id: String,
}
pub enum Change {
    Create(Edit),
    Update(Edit),
    Delete(Delete),
    Reconcile,
}

fn conflict() -> Failure {
    Failure::new(
        "group_unavailable",
        "That output group is unavailable or still in use",
    )
}
fn invalid() -> Failure {
    Failure::new(
        "invalid_params",
        "Choose a name and two to eight physical outputs",
    )
}

impl Group {
    fn new(id: String, name: String, mut members: Vec<String>) -> Result<Self> {
        if !storage::group_id(&id)
            || !(2..=8).contains(&members.len())
            || members.iter().any(|m| !storage::group_member(m))
        {
            return Err(invalid());
        }
        members.sort();
        members.dedup();
        let name = storage::label(&json!(name), 48);
        if name.is_empty() || members.len() < 2 {
            return Err(invalid());
        }
        Ok(Self {
            sink: format!("omarchy_audio_group_{id}"),
            id,
            name,
            members,
        })
    }
    fn arguments(&self) -> String {
        format!(
            "sink_name={} sinks={} sink_properties=\"device.description=Omarchy_Output_Group application.id={} node.virtual=true omarchy.audio.group.id={}\" latency_compensate=true",
            self.sink,
            self.members.join(","),
            OWNER,
            self.id
        )
    }
}

pub fn apply(native: &native::Handle, storage: &Storage, change: Change) -> Result<Value> {
    let graph = native.snapshot();
    let generation = match &change {
        Change::Create(p) | Change::Update(p) => &p.generation,
        Change::Delete(p) => &p.generation,
        Change::Reconcile => &graph.generation,
    };
    if !graph.ready || graph.generation != *generation {
        return Err(Failure::new(
            "stale_target",
            "Audio devices changed; refresh and try again",
        ));
    }
    let before = storage.read(Kind::Rules)?;
    let mut groups: Vec<Group> =
        serde_json::from_value(before["outputGroups"].clone()).map_err(|_| invalid())?;
    let mut server = Server {
        pulse: Session::connect()?,
        native,
        generation: generation.clone(),
    };
    if matches!(change, Change::Reconcile) {
        return server
            .reconcile(&groups)
            .map(|()| json!({"outcome":"applied"}));
    }
    let (old, new) = match change {
        Change::Create(params) => {
            if !params.id.is_empty() || groups.len() >= 16 {
                return Err(invalid());
            }
            let mut bytes = [0; 8];
            std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
            let id: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
            let new = Group::new(id, params.name, params.members)?;
            if groups.iter().any(|g| g.id == new.id) || server.owned(&new)?.is_some() {
                return Err(conflict());
            }
            (None, Some(new))
        }
        Change::Update(params) => {
            let old = groups
                .iter()
                .find(|g| g.id == params.id)
                .cloned()
                .ok_or_else(conflict)?;
            let new = Group::new(params.id, params.name, params.members)?;
            (Some(old), Some(new))
        }
        Change::Delete(params) => {
            if !storage::group_id(&params.id) {
                return Err(invalid());
            }
            let old = groups
                .iter()
                .find(|g| g.id == params.id)
                .cloned()
                .ok_or_else(conflict)?;
            if before["appRules"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["target"] == old.sink)
            {
                return Err(conflict());
            }
            (Some(old), None)
        }
        Change::Reconcile => unreachable!(),
    };
    if let Some(new) = &new {
        if groups.iter().any(|g| {
            g.id != new.id && (g.name.eq_ignore_ascii_case(&new.name) || g.members == new.members)
        }) {
            return Err(invalid());
        }
        server.require_members(new)?;
    }
    let id = old.as_ref().or(new.as_ref()).unwrap().id.clone();
    let previous = old.as_ref().map(|g| server.owned(g)).transpose()?.flatten();
    let replacing = old
        .as_ref()
        .is_some_and(|old| new.as_ref().is_none_or(|new| new.members != old.members));
    if replacing {
        if let Some(old) = &old {
            server.remove(old, false)?;
        }
    }
    let mut created = false;
    let result: Result<Value> = (|| {
        if let Some(new) = &new {
            created = server.ensure(new)?;
        }
        groups.retain(|g| g.id != id);
        if let Some(new) = &new {
            groups.push(new.clone());
        }
        server.guard()?;
        storage.update(Kind::Rules, |rules| {
            if *rules != before {
                return Err(Failure::new(
                    "conflict",
                    "Saved audio rules changed during the operation",
                ));
            }
            rules["outputGroups"] = json!(groups);
            if new.is_none() {
                let sink = &old.as_ref().unwrap().sink;
                rules["devices"]["aliases"]
                    .as_object_mut()
                    .unwrap()
                    .shift_remove(sink);
                for key in ["favorites", "hidden"] {
                    rules["devices"][key]
                        .as_array_mut()
                        .unwrap()
                        .retain(|name| name != sink);
                }
            }
            Ok(())
        })?;
        Ok(json!({"outcome":"applied", "id":id}))
    })();
    match result {
        Ok(value) => Ok(value),
        Err(error) => {
            // Never guess after an unconfirmed module request or server restart.
            if error.outcome == "unknown" || server.guard().is_err() {
                return Err(Failure::unknown(
                    "The output group changed and could not be fully restored",
                ));
            }
            let rollback = (|| {
                if created {
                    server.remove(new.as_ref().unwrap(), false)?;
                }
                if replacing && previous.is_some() {
                    server.ensure(old.as_ref().unwrap())?;
                }
                Ok::<_, Failure>(())
            })();
            if rollback.is_err() {
                Err(Failure::unknown(
                    "The output group changed and could not be fully restored",
                ))
            } else {
                Err(error)
            }
        }
    }
}

struct Server<'a> {
    pulse: Session,
    native: &'a native::Handle,
    generation: String,
}
impl Server<'_> {
    fn guard(&self) -> Result<()> {
        let graph = self.native.snapshot();
        if graph.ready && graph.generation == self.generation {
            Ok(())
        } else {
            Err(Failure::unknown(
                "The audio server changed during the output group operation",
            ))
        }
    }
    fn members_present(&mut self, group: &Group) -> Result<bool> {
        self.guard()?;
        let sinks = self.pulse.sinks()?;
        Ok(group.members.iter().all(|name| {
            let mut matches = sinks.iter().filter(|s| s.name.as_deref() == Some(name));
            matches.next().is_some_and(physical) && matches.next().is_none()
        }))
    }
    fn require_members(&mut self, group: &Group) -> Result<()> {
        if self.members_present(group)? {
            Ok(())
        } else {
            Err(conflict())
        }
    }
    fn owned(&mut self, group: &Group) -> Result<Option<SinkInfo<'static>>> {
        self.guard()?;
        let sinks = self.pulse.sinks()?;
        let modules = self.pulse.modules()?;
        let mut named = sinks
            .into_iter()
            .filter(|s| s.name.as_deref() == Some(&group.sink));
        let sink = named.next();
        if named.next().is_some() {
            return Err(conflict());
        }
        let owned: Vec<_> = modules
            .iter()
            .filter(|m| {
                m.name.as_deref() == Some("module-combine-sink")
                    && module_owned(m.argument.as_deref().unwrap_or(""), group)
            })
            .collect();
        match sink {
            None if owned.is_empty() => Ok(None),
            Some(sink)
                if owned.len() == 1
                    && sink.owner_module == Some(owned[0].index)
                    && sink
                        .proplist
                        .get_str("pulse.module.id")
                        .and_then(|v| v.parse::<u32>().ok())
                        == sink.owner_module
                    && sink_owned(&sink, group) =>
            {
                Ok(Some(sink))
            }
            _ => Err(conflict()),
        }
    }
    fn ensure(&mut self, group: &Group) -> Result<bool> {
        self.require_members(group)?;
        if self.owned(group)?.is_some() {
            return Ok(false);
        }
        self.guard()?;
        let module = self.pulse.load(&group.arguments())?;
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if self
                .owned(group)
                .is_ok_and(|s| s.is_some_and(|s| s.owner_module == Some(module)))
            {
                return Ok(true);
            }
            if Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        self.guard()?;
        // The returned module handle is valid only on this uninterrupted connection.
        let modules = self
            .pulse
            .modules()
            .map_err(|_| Failure::unknown("Could not verify ownership of the new output group"))?;
        if modules
            .iter()
            .any(|m| m.index == module && module_owned(m.argument.as_deref().unwrap_or(""), group))
        {
            self.pulse.unload(module)?;
            self.absent(group, module).map_err(|_| {
                Failure::unknown("Could not verify cleanup of the new output group")
            })?;
        } else if modules.iter().any(|m| m.index == module) {
            return Err(Failure::unknown(
                "Could not verify ownership of the new output group",
            ));
        }
        Err(Failure::new(
            "group_failed",
            "Could not create the output group",
        ))
    }
    fn remove(&mut self, group: &Group, degraded: bool) -> Result<()> {
        let Some(sink) = self.owned(group)? else {
            return Ok(());
        };
        // Recheck identity immediately before unloading, including the sink serial.
        let current = self.owned(group)?.ok_or_else(conflict)?;
        if current.index != sink.index
            || current.owner_module != sink.owner_module
            || current.proplist.get_str("object.serial") != sink.proplist.get_str("object.serial")
        {
            return Err(conflict());
        }
        if degraded {
            if self.members_present(group)? {
                return Err(conflict());
            }
        } else if self.pulse.in_use(&current)? {
            return Err(conflict());
        }
        self.guard()?;
        let module = sink.owner_module.ok_or_else(conflict)?;
        self.pulse.unload(module)?;
        self.absent(group, module)
            .map_err(|_| Failure::unknown("Could not verify output group removal"))
    }
    fn absent(&mut self, group: &Group, module: u32) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            self.guard()?;
            if !self
                .pulse
                .sinks()?
                .iter()
                .any(|s| s.name.as_deref() == Some(&group.sink))
                && !self.pulse.modules()?.iter().any(|m| m.index == module)
            {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(Failure::unknown("Could not verify output group removal"));
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    fn reconcile(&mut self, groups: &[Group]) -> Result<()> {
        let mut failed = false;
        for group in groups {
            let result = if self.members_present(group)? {
                self.ensure(group).map(|_| ())
            } else {
                self.remove(group, true)
            };
            if let Err(error) = result {
                if error.outcome == "unknown" {
                    return Err(error);
                }
                failed = true;
            }
        }
        let ids: BTreeSet<_> = groups.iter().map(|g| g.id.as_str()).collect();
        for sink in self.pulse.sinks()? {
            let Some(name) = sink.name.as_deref() else {
                continue;
            };
            let Some(id) = name
                .strip_prefix("omarchy_audio_group_")
                .filter(|id| storage::group_id(id))
            else {
                continue;
            };
            if ids.contains(id) {
                continue;
            }
            let group = Group {
                id: id.into(),
                sink: name.into(),
                name: String::new(),
                members: Vec::new(),
            };
            if sink_owned(&sink, &group) && self.owned(&group).is_ok_and(|s| s.is_some()) {
                if let Err(error) = self.remove(&group, false) {
                    if error.outcome == "unknown" {
                        return Err(error);
                    }
                }
            }
        }
        if failed {
            Err(Failure::new(
                "group_failed",
                "Some output groups could not be restored",
            ))
        } else {
            Ok(())
        }
    }
}

fn module_owned(arguments: &str, group: &Group) -> bool {
    [
        format!("sink_name={}", group.sink),
        format!("application.id={OWNER}"),
        format!("omarchy.audio.group.id={}", group.id),
    ]
    .iter()
    .all(|expected| {
        arguments
            .split_ascii_whitespace()
            .any(|word| word.trim_matches(['\'', '"']) == expected)
    })
}
fn sink_owned(sink: &SinkInfo<'_>, group: &Group) -> bool {
    let owner = sink.proplist.get_str("application.id").unwrap_or_default();
    let id = sink
        .proplist
        .get_str("omarchy.audio.group.id")
        .unwrap_or_default();
    (owner == OWNER
        && id == group.id
        && matches!(
            sink.proplist.get_str("node.virtual").as_deref(),
            Some("true" | "1")
        ))
        || (owner.is_empty()
            && id.is_empty()
            && sink.description.as_deref() == Some("Omarchy_Output_Group"))
}
fn physical(sink: &SinkInfo<'_>) -> bool {
    sink.proplist.get_str("application.id").as_deref() != Some(OWNER)
        && !matches!(
            sink.proplist.get_str("node.virtual").as_deref(),
            Some("true" | "1")
        )
        && !matches!(
            sink.proplist.get_str("device.class").as_deref(),
            Some("filter" | "monitor")
        )
        && !matches!(
            sink.proplist.get_str("factory.name").as_deref(),
            Some("support.null-audio-sink" | "filter-chain")
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validate_members_and_module_ownership() {
        let id = "0123456789abcdef".to_string();
        assert!(Group::new(id.clone(), "Desk".into(), vec!["a".into(), "a".into()]).is_err());
        assert!(
            Group::new(
                id.clone(),
                "Desk".into(),
                vec!["a".into(), "bad name".into()]
            )
            .is_err()
        );
        let group = Group::new(id, " Desk\n ".into(), vec!["b".into(), "a".into()]).unwrap();
        assert_eq!(group.name, "Desk");
        assert_eq!(group.members, ["a", "b"]);
        assert!(module_owned(&group.arguments(), &group));
        assert!(!module_owned(
            &group
                .arguments()
                .replace(OWNER, "ssupt.audio-control.foreign"),
            &group
        ));
        assert!(!module_owned(
            &group.arguments().replace("sink_name=", "other_sink_name="),
            &group
        ));
    }
}
