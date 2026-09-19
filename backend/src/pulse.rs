//! Short-lived Pulse connections for server-owned groups and diagnostic formats.
//! The mainloop and all callbacks stay on the calling blocking worker.
use crate::protocol::{Failure, Result};
use libpulse_binding as pulse;
use pulse::callbacks::ListResult;
use pulse::context::{
    Context, FlagSet, State,
    introspect::{ModuleInfo, SinkInfo, SourceInfo},
};
use pulse::mainloop::standard::Mainloop;
use pulse::operation::{Operation, State as OperationState};
use std::{
    cell::RefCell,
    rc::Rc,
    time::{Duration, Instant},
};

pub struct Session {
    context: Context,
    mainloop: Mainloop,
    deadline: Instant,
}

fn unavailable() -> Failure {
    Failure::new("pulse_unavailable", "Could not inspect the audio server")
}

impl Session {
    pub fn connect() -> Result<Self> {
        let mainloop = Mainloop::new().ok_or_else(unavailable)?;
        let mut context =
            Context::new(&mainloop, "Omarchy Audio Control").ok_or_else(unavailable)?;
        context
            .connect(None, FlagSet::NOAUTOSPAWN, None)
            .map_err(|_| unavailable())?;
        let mut session = Self {
            context,
            mainloop,
            deadline: Instant::now() + Duration::from_secs(20),
        };
        let deadline = Instant::now() + Duration::from_secs(3);
        while session.context.get_state() != State::Ready {
            session.step(deadline)?;
        }
        Ok(session)
    }

    fn step(&mut self, deadline: Instant) -> Result<()> {
        if Instant::now() >= deadline.min(self.deadline)
            || matches!(self.context.get_state(), State::Failed | State::Terminated)
        {
            return Err(unavailable());
        }
        self.mainloop
            .prepare(Some(pulse::time::MicroSeconds(20_000)))
            .map_err(|_| unavailable())?;
        self.mainloop.poll().map_err(|_| unavailable())?;
        self.mainloop.dispatch().map_err(|_| unavailable())?;
        Ok(())
    }

    fn finish<T: ?Sized>(&mut self, mut operation: Operation<T>, mutation: bool) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(3);
        while operation.get_state() == OperationState::Running {
            if let Err(error) = self.step(deadline) {
                operation.cancel();
                return Err(if mutation {
                    Failure::unknown("The audio server did not confirm the output group change")
                } else {
                    error
                });
            }
        }
        if operation.get_state() != OperationState::Done {
            return Err(unavailable());
        }
        Ok(())
    }

    pub fn sinks(&mut self) -> Result<Vec<SinkInfo<'static>>> {
        self.ready()?;
        let list = Rc::new(RefCell::new(List::default()));
        let callback = list.clone();
        let op = self.context.introspect().get_sink_info_list(move |item| {
            callback
                .borrow_mut()
                .push(item.map_owned(SinkInfo::to_owned), 512);
        });
        self.finish(op, false)?;
        Rc::try_unwrap(list).ok().unwrap().into_inner().result()
    }

    pub fn sources(&mut self) -> Result<Vec<SourceInfo<'static>>> {
        self.ready()?;
        let list = Rc::new(RefCell::new(List::default()));
        let callback = list.clone();
        let op = self.context.introspect().get_source_info_list(move |item| {
            callback
                .borrow_mut()
                .push(item.map_owned(SourceInfo::to_owned), 512);
        });
        self.finish(op, false)?;
        Rc::try_unwrap(list).ok().unwrap().into_inner().result()
    }

    pub fn modules(&mut self) -> Result<Vec<ModuleInfo<'static>>> {
        self.ready()?;
        let list = Rc::new(RefCell::new(List::default()));
        let callback = list.clone();
        let op = self.context.introspect().get_module_info_list(move |item| {
            callback
                .borrow_mut()
                .push(item.map_owned(ModuleInfo::to_owned), 1024);
        });
        self.finish(op, false)?;
        Rc::try_unwrap(list).ok().unwrap().into_inner().result()
    }

    pub fn in_use(&mut self, sink: &SinkInfo<'_>) -> Result<bool> {
        self.ready()?;
        let default = Rc::new(RefCell::new(None));
        let callback = default.clone();
        let op = self.context.introspect().get_server_info(move |info| {
            *callback.borrow_mut() =
                Some(info.default_sink_name.as_deref().unwrap_or("").to_owned());
        });
        self.finish(op, false)?;
        let default = default.borrow().clone().ok_or_else(unavailable)?;
        if sink.name.as_deref() == Some(default.as_str()) {
            return Ok(true);
        }
        let list = Rc::new(RefCell::new(List::default()));
        let callback = list.clone();
        let op = self
            .context
            .introspect()
            .get_sink_input_info_list(move |item| {
                callback.borrow_mut().push(item.map_owned(|i| i.sink), 4096);
            });
        self.finish(op, false)?;
        Ok(Rc::try_unwrap(list)
            .ok()
            .unwrap()
            .into_inner()
            .result()?
            .contains(&sink.index))
    }

    pub fn load(&mut self, arguments: &str) -> Result<u32> {
        self.ready()?;
        let index = Rc::new(RefCell::new(None));
        let callback = index.clone();
        let op =
            self.context
                .introspect()
                .load_module("module-combine-sink", arguments, move |id| {
                    *callback.borrow_mut() = Some(id)
                });
        self.finish(op, true)?;
        index
            .borrow()
            .filter(|id| *id != pulse::def::INVALID_INDEX)
            .ok_or_else(|| Failure::new("group_failed", "Could not create the output group"))
    }

    pub fn unload(&mut self, id: u32) -> Result<()> {
        self.ready()?;
        let success = Rc::new(RefCell::new(false));
        let callback = success.clone();
        let op = self
            .context
            .introspect()
            .unload_module(id, move |ok| *callback.borrow_mut() = ok);
        self.finish(op, true)?;
        if *success.borrow() {
            Ok(())
        } else {
            Err(Failure::unknown("Could not confirm output group removal"))
        }
    }

    fn ready(&self) -> Result<()> {
        if self.context.get_state() != State::Ready || Instant::now() >= self.deadline {
            Err(unavailable())
        } else {
            Ok(())
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.context.disconnect();
    }
}

struct List<T> {
    values: Vec<T>,
    complete: bool,
    failed: bool,
}
impl<T> Default for List<T> {
    fn default() -> Self {
        Self {
            values: Vec::new(),
            complete: false,
            failed: false,
        }
    }
}
impl<T> List<T> {
    fn push(&mut self, item: ListResult<T>, limit: usize) {
        match item {
            ListResult::Item(value) if self.values.len() < limit => self.values.push(value),
            ListResult::End => self.complete = true,
            _ => self.failed = true,
        }
    }
    fn result(self) -> Result<Vec<T>> {
        if self.complete && !self.failed {
            Ok(self.values)
        } else {
            Err(unavailable())
        }
    }
}
trait MapOwned<T> {
    fn map_owned<U>(self, map: impl FnOnce(T) -> U) -> ListResult<U>;
}
impl<T> MapOwned<T> for ListResult<T> {
    fn map_owned<U>(self, map: impl FnOnce(T) -> U) -> ListResult<U> {
        match self {
            ListResult::Item(v) => ListResult::Item(map(v)),
            ListResult::End => ListResult::End,
            ListResult::Error => ListResult::Error,
        }
    }
}
