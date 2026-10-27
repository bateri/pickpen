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
mod source;
mod values;

use std::fs::File;
use std::io::{self, IsTerminal, Read, Write};
use std::process::ExitCode;
use std::sync::Arc;

use pencere::{EndedBy, Options, Outcome, Terminal, ViewControl};

use crate::args::{Parsed, Run};
use crate::input::Record;
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

/// A person chooses in the pane: the rows come from `stream`, or with `--reload` from its command.
fn choose(run: Run, stream: Option<Box<dyn Read + Send>>) -> ExitCode {
    let rule = if run.confirm {
        run.where_.as_deref()
    } else {
        None
    };
    let shared = Shared::new(Picker::new(&run.query, rule, run.fuzzy));
    match (stream, &run.reload) {
        (Some(stream), _) => source::read_into(&shared, run.cut.clone(), stream, 0),
        (None, Some(command)) => source::reload(&shared, command, &run.cut),
        (None, None) => {}
    }

    let terminal = match Terminal::controlling() {
        Ok(terminal) => terminal,
        Err(_) => {
            source::stop(&shared);
            return no_view();
        }
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
    // What --reload last ran goes with the view.
    source::stop(&shared);
    let answer = shared
        .answer
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
    if let Some(served::Answer { rows, shape, key }) = answer {
        let picker = shared.lock();
        let records: Vec<&Record> = rows
            .iter()
            .map(|&id| &picker.records[id as usize])
            .collect();
        let mut text = output::render(&records, &shape, &picker.source(), run.print0);
        if !run.expect.is_empty() {
            text = output::key_line(key.as_deref(), run.print0) + &text;
        }
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
    let headless = run.where_.is_some() && !run.confirm;
    if let Some(command) = run.reload.clone() {
        if !headless {
            return choose(run, None);
        }
        // With nobody to ask, the command's rows once, its stderr pickpen's own.
        return match source::spawn(&command, false) {
            Ok(mut child) => {
                let code = match child.stdout.take() {
                    Some(stdout) => headless::run(&run, Box::new(stdout)),
                    None => ExitCode::from(1),
                };
                let _ = child.kill();
                let _ = child.wait();
                code
            }
            Err(why) => quit(
                66,
                &format!("cannot run --reload: {}", args::os_words(&why)),
            ),
        };
    }
    let stream = match input_of(&run) {
        Ok(stream) => stream,
        Err(code) => return code,
    };
    if headless {
        headless::run(&run, stream)
    } else {
        choose(run, Some(stream))
    }
}
