//! `--where` with nobody to ask: the rows the query matches go out, one by one as they come when
//! the shape allows (as grep's do), or all at the end (sorted, or a JSON document).

use std::io::{self, Read, Write};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::args::Run;
use crate::input::{self, Format, Record, Sink};
use crate::output::{self, Source};
use crate::query::{self, Query};
use crate::{quit, say};

/// How long a row written may wait in the buffer before it is handed on, while no more come.
const FLUSH_AFTER: Duration = Duration::from_millis(50);

/// What a write error means: what reads the output has gone (as a SIGPIPE would end the program,
/// quietly, 141), or the output cannot be written (74).
fn write_failed(why: &io::Error) -> ExitCode {
    if why.kind() == io::ErrorKind::BrokenPipe {
        ExitCode::from(141)
    } else {
        quit(74, &format!("cannot write: {why}"))
    }
}

/// Writes the last of the output and ends with `code`.
pub fn write_all(bytes: &[u8], code: u8) -> ExitCode {
    let mut out = io::stdout().lock();
    match out.write_all(bytes).and_then(|()| out.flush()) {
        Ok(()) => ExitCode::from(code),
        Err(why) => write_failed(&why),
    }
}

/// stdout, buffered, handed on when a moment passes with nothing more to write.
struct Out {
    buffer: Mutex<(Vec<u8>, Option<io::Error>)>,
}

impl Out {
    fn write(&self, text: &str) {
        let mut held = self
            .buffer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        held.0.extend_from_slice(text.as_bytes());
        if held.0.len() >= 64 * 1024 {
            Self::flush_held(&mut held);
        }
    }

    fn flush(&self) {
        let mut held = self
            .buffer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Self::flush_held(&mut held);
    }

    fn flush_held(held: &mut (Vec<u8>, Option<io::Error>)) {
        if held.0.is_empty() || held.1.is_some() {
            return;
        }
        let mut out = io::stdout().lock();
        if let Err(why) = out.write_all(&held.0).and_then(|()| out.flush()) {
            held.1 = Some(why);
        }
        held.0.clear();
    }

    /// A write that failed ends the program now: there is no one to write the rest to.
    fn failed(&self) -> Option<ExitCode> {
        let held = self
            .buffer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        held.1.as_ref().map(write_failed)
    }
}

struct Headless<'a> {
    run: &'a Run,
    where_: String,
    query: Option<Query>,
    names: Vec<String>,
    heading: Option<String>,
    format: Option<Format>,
    held: Vec<Record>,
    count: usize,
    headed: bool,
    out: Arc<Out>,
    /// A problem of the command line found once the columns are known: the status and the words.
    stop: Option<(u8, String)>,
}

impl Headless<'_> {
    fn source(&self) -> Source<'_> {
        Source {
            format: self.format,
            names: &self.names,
            heading: self.heading.as_deref(),
        }
    }

    /// Whether rows go out as they come: not when they are put in an order first, a column's or,
    /// with fuzzy words, best match first.
    fn one_by_one(&self) -> bool {
        self.run.sort.is_none()
            && !self.query.as_ref().is_some_and(Query::ranks)
            && output::streams(&self.run.shape, self.format)
    }
}

impl Sink for Headless<'_> {
    fn format(&mut self, format: Format) {
        self.format = Some(format);
    }

    fn columns(&mut self, names: Vec<String>, heading: Option<String>) {
        if self.names.is_empty() {
            for name in query::unknown_names(&self.where_, &names) {
                say(&format!(
                    "there is no column named {}: that term is looked for as a word",
                    serde_json::Value::from(name)
                ));
            }
        }
        self.names = names;
        if heading.is_some() {
            self.heading = heading;
        }
        self.query = Some(query::parse_as(&self.where_, &self.names, self.run.fuzzy));
        if let Some(problem) = output::problem_of(&self.run.shape, &self.names) {
            self.stop.get_or_insert((64, problem));
        }
        if let Some(sort) = &self.run.sort
            && query::column_named(&self.names, &sort.column).is_none()
        {
            self.stop.get_or_insert((
                64,
                format!(
                    "there is no column named {} to sort by",
                    serde_json::Value::from(sort.column.clone())
                ),
            ));
        }
    }

    fn record(&mut self, record: Record) {
        if self.stop.is_some() {
            return;
        }
        let query = self
            .query
            .get_or_insert_with(|| query::parse_as(&self.where_, &self.names, self.run.fuzzy));
        if !query::matches(query, &record.cells, &query::lower_of(&record.cells)) {
            return;
        }
        self.count += 1;
        if !self.one_by_one() {
            self.held.push(record);
            return;
        }
        if !self.headed {
            self.headed = true;
            if !self.run.expect.is_empty() {
                self.out.write(&output::key_line(None, self.run.print0));
            }
            self.out.write(&output::head(
                &self.run.shape,
                &self.source(),
                self.run.print0,
            ));
        }
        self.out.write(&output::one(
            &record,
            &self.run.shape,
            &self.source(),
            self.run.print0,
        ));
    }

    fn problem(&mut self, text: String) {
        let mut chars = text.chars();
        let first = chars
            .next()
            .map(|c| c.to_lowercase().collect::<String>())
            .unwrap_or_default();
        say(&format!("{first}{}", chars.as_str()));
    }

    fn finish(&mut self) {}

    fn stop(&self) -> bool {
        self.stop.is_some() || self.out.failed().is_some()
    }
}

pub fn run(run: &Run, stream: Box<dyn Read + Send>) -> ExitCode {
    let out = Arc::new(Out {
        buffer: Mutex::new((Vec::new(), None)),
    });
    // Rows that wait in the buffer are handed on a moment later, so that `tail -f | pickpen --where`
    // writes each as it comes without a write for every row of a large input.
    let flusher = out.clone();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(FLUSH_AFTER);
            flusher.flush();
        }
    });
    let mut headless = Headless {
        run,
        where_: run.where_.clone().unwrap_or_default(),
        query: None,
        names: Vec::new(),
        heading: None,
        format: None,
        held: Vec::new(),
        count: 0,
        headed: false,
        out: out.clone(),
        stop: None,
    };
    let read = input::read(stream, run.cut.clone(), &mut headless);
    if let Some((code, words)) = headless.stop.take() {
        out.flush();
        return quit(code, &words);
    }
    out.flush();
    if let Some(code) = out.failed() {
        return code;
    }
    if let Err(why) = read {
        let from = run.file.as_deref().unwrap_or("stdin");
        return quit(
            66,
            &format!("cannot read {from}: {}", crate::args::os_words(&why)),
        );
    }
    if headless.format == Some(Format::Json) && headless.names.is_empty() {
        return quit(65, "the input could not be read");
    }
    let mut rest = String::new();
    if !headless.one_by_one() {
        let mut held = std::mem::take(&mut headless.held);
        if let Some(sort) = &run.sort
            && let Some(column) = query::column_named(&headless.names, &sort.column)
        {
            // A stable sort keeps ties in the input's order, as the view does.
            let mut keyed: Vec<(query::SortKey, Record)> = held
                .into_iter()
                .map(|record| {
                    (
                        query::sort_key(record.cells.get(column).map_or("", String::as_str)),
                        record,
                    )
                })
                .collect();
            keyed.sort_by(|a, b| query::compare_ordered(&a.0, &b.0, sort.descending));
            held = keyed.into_iter().map(|(_, record)| record).collect();
        } else if let Some(query) = headless.query.as_ref().filter(|q| q.ranks()) {
            // Best match first, as the view puts them; ties in the input's order.
            held.sort_by_cached_key(|record| {
                std::cmp::Reverse(query.score(&query::lower_of(&record.cells)))
            });
        }
        let records: Vec<&Record> = held.iter().collect();
        rest = output::render(&records, &run.shape, &headless.source(), run.print0);
        if !run.expect.is_empty() && !rest.is_empty() {
            rest = output::key_line(None, run.print0) + &rest;
        }
    }
    write_all(rest.as_bytes(), if headless.count > 0 { 0 } else { 1 })
}
