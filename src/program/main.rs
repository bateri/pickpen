//! pickpen: rows come in on stdin (or from a file), a person chooses in the terminal pane, and the
//! rows chosen go out on stdout, for what comes next in the pipeline.
//!
//!   ps aux | pickpen --field PID | xargs kill
//!
//! stdin and stdout are the pipeline's, so the view is asked for on the terminal itself (the
//! controlling terminal, pencere §13), always: pickpen never guesses whether it is in a pipeline.
//! With `--where` and no `--confirm` nobody is asked: the rows the query matches go out, the same
//! in a terminal and in cron.

mod args;
mod command;
mod headless;
mod icons;
mod input;
mod output;
mod picker;
mod preview;
mod query;
mod served;
mod values;

use std::fs::File;
use std::io::{self, IsTerminal, Read, Write};
use std::process::ExitCode;
use std::sync::Arc;

use pencere::{EndedBy, Options, Outcome, Terminal, ViewControl};

use crate::args::{Parsed, Run};
use crate::input::{Format, Record, Sink};
use crate::picker::Picker;
use crate::served::Shared;

/// The version the package says, which a release changes in Cargo.toml and nowhere else.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn say(message: &str) {
    eprintln!("pickpen: {message}");
}

/// Says why, and ends with a status that says what happened.
pub fn quit(code: u8, message: &str) -> ExitCode {
    say(message);
    ExitCode::from(code)
}

/// What the rows come from: the file named, or stdin, which must not be a person typing.
fn input_of(run: &Run) -> Result<Box<dyn Read + Send>, ExitCode> {
    match &run.file {
        None => {
            // A person who typed `pickpen` alone would wait on a read nobody feeds.
            if io::stdin().is_terminal() {
                return Err(quit(
                    64,
                    "give rows on stdin or name a FILE (pickpen --help says how it is used)",
                ));
            }
            Ok(Box::new(io::stdin()))
        }
        // Opened now, so that a file that cannot be read is said before any view opens.
        Some(path) => match File::open(path) {
            Ok(file) => Ok(Box::new(file)),
            Err(why) => Err(quit(
                66,
                &format!("cannot read {path}: {}", args::os_words(&why)),
            )),
        },
    }
}

/// The input as it is read, into the picker the view is served from.
struct Feed {
    shared: Arc<Shared>,
}

impl Sink for Feed {
    fn format(&mut self, format: Format) {
        self.shared.lock().format = Some(format);
    }

    fn columns(&mut self, names: Vec<String>, heading: Option<String>) {
        self.shared.lock().columns(names, heading);
        self.shared.ring();
    }

    fn record(&mut self, record: Record) {
        self.shared.lock().record(record);
        self.shared.ring();
    }

    fn problem(&mut self, text: String) {
        self.shared.lock().problem(text);
        self.shared.ring();
    }

    fn finish(&mut self) {
        self.shared.lock().finish();
        self.shared.ring();
    }

    fn stop(&self) -> bool {
        self.shared.lock().capped
    }
}

/// A person chooses in the pane.
fn choose(run: Run, stream: Box<dyn Read + Send>) -> ExitCode {
    let rule = if run.confirm {
        run.where_.as_deref()
    } else {
        None
    };
    let shared = Shared::new(Picker::new(&run.query, rule, run.fuzzy));
    let feed = shared.clone();
    let cut = run.cut.clone();
    std::thread::spawn(move || {
        let mut sink = Feed {
            shared: feed.clone(),
        };
        if let Err(why) = input::read(stream, cut, &mut sink) {
            sink.problem(format!(
                "The input could not be read: {}",
                args::os_words(&why)
            ));
            sink.finish();
        }
    });

    let terminal = match Terminal::controlling() {
        Ok(terminal) => terminal,
        Err(_) => return no_view(),
    };
    let run = Arc::new(run);
    let control = ViewControl::new();
    let mut options = Options::new()
        .app(pencere::app!())
        .program("pickpen")
        // What a terminal writes above the view: the same for every run, as a program's name is;
        // `--title` is the view's to say, at its top.
        .title("Pick")
        .terminal(terminal);
    for icon in icons::icons() {
        options = options.icon(icon);
    }
    let options = served::serve(
        options.control(control.clone()),
        &shared,
        &run,
        &control,
        VERSION,
    );
    let outcome = pencere::serve(options);
    let answer = shared
        .answer
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
    if let Some((rows, shape)) = answer {
        let picker = shared.lock();
        let records: Vec<&Record> = rows
            .iter()
            .map(|&id| &picker.records[id as usize])
            .collect();
        let text = output::render(&records, &shape, &picker.source(), run.print0);
        return headless::write_all(text.as_bytes(), 0);
    }
    if *shared
        .cancelled
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
    {
        return quit(1, "nothing was chosen");
    }
    match outcome {
        Err(why) => quit(1, &format!("the view could not be shown: {why}")),
        Ok(Outcome::NoView(no_view))
            if matches!(no_view.reason, pencere::NoViewReason::Interrupted(_)) =>
        {
            ExitCode::from(130)
        }
        Ok(Outcome::NoView(_)) => self::no_view(),
        Ok(Outcome::Closed(closed)) if matches!(closed.by, EndedBy::Signal(_)) => {
            ExitCode::from(130)
        }
        Ok(Outcome::Closed(_)) => quit(1, "nothing was chosen"),
    }
}

fn no_view() -> ExitCode {
    quit(
        2,
        "choosing rows needs a terminal that shows pencere views; --where QUERY alone runs without one",
    )
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let run = match args::parse(&argv) {
        Ok(Parsed::Help) => {
            let _ = writeln!(io::stdout(), "{}", args::USAGE);
            return ExitCode::SUCCESS;
        }
        Ok(Parsed::Version) => {
            let _ = writeln!(io::stdout(), "pickpen {VERSION}");
            return ExitCode::SUCCESS;
        }
        Ok(Parsed::Run(run)) => run,
        Err(message) => {
            return quit(
                64,
                &format!("{message} (pickpen --help says how it is used)"),
            );
        }
    };
    let stream = match input_of(&run) {
        Ok(stream) => stream,
        Err(code) => return code,
    };
    if run.where_.is_some() && !run.confirm {
        headless::run(&run, stream)
    } else {
        choose(run, stream)
    }
}
