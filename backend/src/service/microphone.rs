//! Microphone session ownership, admission, cancellation and clip publication.
use super::{Busy, Service};
use crate::files::FileLock;
use crate::microphone::{self, Control};
use crate::native::Identity;
use crate::protocol::{Failure, Request, Result};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::watch;

#[derive(Default)]
pub(super) struct Session {
    owner: String,
    clip: Vec<u8>,
    cancel: Option<watch::Sender<Control>>,
}

impl Session {
    fn clip_state(&self) -> &'static str {
        if self.clip.is_empty() {
            "idle"
        } else {
            "ready"
        }
    }
}

impl Service {
    fn publish_microphone(&self, owner: &str, phase: &str, error: &str) {
        self.update_state(|state| {
            state["microphone"] = json!({"owner": owner, "state": phase, "error": error});
        });
    }

    pub(super) async fn stop_microphone(&self, owner: Option<&str>, discard: bool) {
        let mut session = self.microphone.lock().await;
        if owner.is_some_and(|owner| session.owner != owner) {
            return;
        }
        if discard {
            session.clip.clear();
        }
        if let Some(cancel) = &session.cancel {
            // Closing/discarding a session is final even if an older stop
            // request is handled later, before the recording task exits.
            cancel.send_modify(|control| {
                if discard {
                    *control = Control::Discard;
                } else if *control == Control::Continue {
                    *control = Control::Stop;
                }
            });
        } else if discard {
            self.publish_microphone(&session.owner, "idle", "");
        }
    }

    pub(super) async fn start_microphone(self: &Arc<Self>, request: &Request) -> Result<Value> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Start {
            owner: String,
            record: bool,
            identity: Option<Identity>,
        }
        let params = request.params::<Start>()?;
        if params.owner.is_empty() || params.owner.len() > 128 {
            return Err(Failure::new("invalid_params", "Invalid microphone owner"));
        }
        let native = self
            .native
            .clone()
            .ok_or_else(|| Failure::new("disconnected", "Native audio is unavailable"))?;
        let transaction = self
            .mutation
            .clone()
            .try_lock_owned()
            .map_err(|_| Failure::new("busy", "Another audio operation is active"))?;
        let mut session = self.microphone.lock().await;
        if session.cancel.is_some() {
            return Err(Failure::new("busy", "A microphone test is active"));
        }
        let clip = if session.owner == params.owner {
            session.clip.clone()
        } else {
            Vec::new()
        };
        if !params.record && clip.is_empty() {
            return Err(Failure::new("no_clip", "Record a microphone test first"));
        }
        let (cancel, receiver) = watch::channel(Control::Continue);
        session.owner = params.owner.clone();
        session.cancel = Some(cancel);
        if params.record {
            session.clip.clear();
        }
        drop(session);
        self.set_busy(true);
        self.publish_microphone(&params.owner, "starting", "");
        let prepared = FileLock::mutation().await.and_then(|lock| {
            if *receiver.borrow() == Control::Continue {
                Ok(lock)
            } else {
                Err(Failure::new(
                    "cancelled",
                    "Microphone test was cancelled before starting",
                ))
            }
        });
        let lock = match prepared {
            Ok(lock) => lock,
            Err(error) => {
                let mut session = self.microphone.lock().await;
                session.cancel = None;
                self.set_busy(false);
                self.publish_microphone(&params.owner, session.clip_state(), "");
                return Err(error);
            }
        };
        let phase = if params.record {
            "recording"
        } else {
            "playing"
        };
        self.publish_microphone(&params.owner, phase, "");
        let service = self.clone();
        tokio::spawn(async move {
            let _transaction = transaction;
            let _lock = lock;
            let _busy = Busy(&service);
            let result =
                microphone::run(params.record, &native, params.identity, clip, receiver).await;
            let mut session = service.microphone.lock().await;
            let discarded = session
                .cancel
                .as_ref()
                .is_some_and(|c| *c.borrow() == Control::Discard);
            session.cancel = None;
            let error = result
                .as_ref()
                .err()
                .map(|e| e.message.clone())
                .unwrap_or_default();
            if discarded || (params.record && result.is_err()) {
                session.clip.clear();
            } else if let Ok(clip) = result {
                session.clip = clip;
            }
            service.publish_microphone(&params.owner, session.clip_state(), &error);
        });
        Ok(json!({"started":true}))
    }

    pub(super) async fn stop_microphone_request(&self, request: &Request) -> Result<Value> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Stop {
            owner: String,
            discard: bool,
        }
        let params = request.params::<Stop>()?;
        self.stop_microphone(Some(&params.owner), params.discard)
            .await;
        Ok(json!({"stopping":true}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_late_stop_cannot_undo_discard() {
        let service = Service::new().unwrap();
        let (cancel, receiver) = watch::channel(Control::Continue);
        {
            let mut session = service.microphone.lock().await;
            session.owner = "closing-window".into();
            session.clip = vec![1, 2];
            session.cancel = Some(cancel);
        }
        service.stop_microphone(Some("closing-window"), true).await;
        service.stop_microphone(Some("closing-window"), false).await;
        assert_eq!(*receiver.borrow(), Control::Discard);
        assert!(service.microphone.lock().await.clip.is_empty());
    }
}
