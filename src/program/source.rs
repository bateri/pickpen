//! What fills the picker the view is served from: the input, read on a thread of its own, or with
//! `--reload` what a command prints, read again whenever the person asks. Each reading fills one
//! generation of the rows (`Picker::generation`): what an earlier one still brings is let go.
//!
//! The command runs as a preview does (pencere §13): in a session of its own, with no terminal and
//! nothing on stdin. What it says on stderr is the view's to show when it fails, since nothing may
//! be printed while the view has the terminal.

use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, MutexGuard, PoisonError};

use crate::args;
use crate::input::{self, Cut, Format, Record, Sink};
use crate::picker::Picker;
use crate::preview;
use crate::served::Shared;

/// The input of one generation of rows, as it is read, into the picker.
struct Feed {
    shared: Arc<Shared>,
    generation: u64,
}

impl Feed {
    /// The picker, while its rows are still this reading's.
    fn picker(&self) -> Option<MutexGuard<'_, Picker>> {
        let picker = self.shared.lock();
        (picker.generation == self.generation).then_some(picker)
    }
}

impl Sink for Feed {
    fn format(&mut self, format: Format) {
        if let Some(mut picker) = self.picker() {
            picker.format = Some(format);
        }
    }

    fn columns(&mut self, names: Vec<String>, heading: Option<String>) {
        if let Some(mut picker) = self.picker() {
            picker.columns(names, heading);
        }
        self.shared.ring();
    }

    fn record(&mut self, record: Record) {
        if let Some(mut picker) = self.picker() {
            picker.record(record);
        }
        self.shared.ring();
    }

    fn problem(&mut self, text: String) {
        if let Some(mut picker) = self.picker() {
            picker.problem(text);
        }
        self.shared.ring();
    }

    fn finish(&mut self) {
        if let Some(mut picker) = self.picker() {
            picker.finish();
        }
        self.shared.ring();
    }

    fn stop(&self) -> bool {
        self.picker().is_none_or(|picker| picker.capped)
    }
}

/// Reads `stream` into the picker on a thread of its own, as the rows of `generation`.
pub fn read_into(shared: &Arc<Shared>, cut: Cut, stream: Box<dyn Read + Send>, generation: u64) {
    let shared = shared.clone();
    std::thread::spawn(move || {
        let mut sink = Feed { shared, generation };
        if let Err(why) = input::read(stream, cut, &mut sink) {
            sink.problem(format!(
                "The input could not be read: {}",
                args::os_words(&why)
            ));
            sink.finish();
        }
    });
}

/// `sh -c COMMAND`, its stdout to be read as the rows: for the view in a session of its own, with
/// no terminal and its stderr kept (`view`); with nobody to ask, with pickpen's own stderr.
pub fn spawn(command: &str, view: bool) -> std::io::Result<Child> {
    let mut sh = Command::new("/bin/sh");
    sh.arg("-c")
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped());
    if view {
        sh.stderr(Stdio::piped());
        preview::own_session(&mut sh);
    }
    sh.spawn()
}

/// Ends the command the rows were last read from, when it is still going: its whole group (a
/// `tail -f` it started, a pipeline).
pub fn stop(shared: &Shared) {
    let reading = shared
        .reading
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take();
    if let Some(group) = reading.and_then(|pid| i32::try_from(pid).ok()) {
        // SAFETY: a plain call with a number; a group that is gone is answered ESRCH.
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
    }
}

/// Reads the rows again from `command` (`--reload`): the rows there were go (`Picker::reset`), the
/// command before is ended, and what this one prints comes in as stdin's rows do. When it ends
/// with another status than 0, the view is told so, with the last line it said on stderr.
pub fn reload(shared: &Arc<Shared>, command: &str, cut: &Cut) {
    stop(shared);
    let generation = {
        let mut picker = shared.lock();
        picker.reset();
        picker.generation
    };
    shared.ring();
    let mut child = match spawn(command, true) {
        Ok(child) => child,
        Err(why) => {
            let mut picker = shared.lock();
            picker.problem(format!("--reload could not run: {}", args::os_words(&why)));
            picker.finish();
            drop(picker);
            shared.ring();
            return;
        }
    };
    let pid = child.id();
    *shared
        .reading
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(pid);
    if let Some(stdout) = child.stdout.take() {
        read_into(shared, cut.clone(), Box::new(stdout), generation);
    }
    let stderr = child.stderr.take();
    let shared = shared.clone();
    std::thread::spawn(move || {
        // Only its last line is shown: the last few kilobytes are kept.
        let mut said = Vec::new();
        if let Some(mut stderr) = stderr {
            let mut piece = [0u8; 4096];
            while let Ok(n) = stderr.read(&mut piece) {
                if n == 0 {
                    break;
                }
                said.extend_from_slice(&piece[..n]);
                if said.len() > 16 * 1024 {
                    said.drain(..said.len() - 4096);
                }
            }
        }
        let status = child.wait();
        {
            let mut reading = shared
                .reading
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if *reading == Some(pid) {
                *reading = None;
            }
        }
        let Ok(status) = status else { return };
        if status.success() {
            return;
        }
        let said = String::from_utf8_lossy(&said);
        let last = said.lines().rev().find(|line| !line.trim().is_empty());
        let how = match status.code() {
            Some(code) => format!("--reload ended with status {code}"),
            None => "--reload was ended by a signal".to_string(),
        };
        let mut picker = shared.lock();
        if picker.generation == generation {
            picker.problem(match last {
                Some(last) => format!("{how}: {}", last.trim()),
                None => how,
            });
        }
        drop(picker);
        shared.ring();
    });
}
