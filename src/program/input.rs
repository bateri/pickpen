//! Reading the pipeline's input as rows: what shape it has (unless `--input` says), and each
//! record as it comes, so that a view opened on `tail -f` shows lines while they arrive.
//!
//! The shape is read from the first lines, never the mode: whether pickpen is in a pipeline is
//! not a question this file asks. A record keeps the text it was read from (`raw`), which is what
//! goes out when the output has the input's shape.
//!
//! Lengths and places within a line (the sample's size, where a table's columns begin) are
//! counted in UTF-16 code units, as the first pickpen, written in JavaScript, counted them, so
//! that a table with characters beyond U+FFFF in it is cut where it was cut before. JSON is read
//! and written as JavaScript reads and writes it (`parse_json`, `stringify`).

use std::borrow::Cow;
use std::collections::HashMap;
use std::io::{self, Read};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Map, Number, Value};

use crate::values::{js_number, js_space, js_trim, utf16_len};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Format {
    Lines,
    Csv,
    Tsv,
    Columns,
    Jsonl,
    Json,
}

pub const FORMATS: [Format; 6] = [
    Format::Lines,
    Format::Csv,
    Format::Tsv,
    Format::Columns,
    Format::Jsonl,
    Format::Json,
];

impl Format {
    pub fn name(self) -> &'static str {
        match self {
            Format::Lines => "lines",
            Format::Csv => "csv",
            Format::Tsv => "tsv",
            Format::Columns => "columns",
            Format::Jsonl => "jsonl",
            Format::Json => "json",
        }
    }

    pub fn from_name(name: &str) -> Option<Format> {
        FORMATS.into_iter().find(|f| f.name() == name)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Record {
    /// The text it was read from, without its line ending and colour codes.
    pub raw: String,
    /// One per column, as text; a record may have fewer than there are columns.
    pub cells: Vec<String>,
    /// For JSON input, the value itself.
    pub value: Option<Value>,
}

pub trait Sink {
    /// The shape, once it is settled: before any columns or records.
    fn format(&mut self, _format: Format) {}
    /// The columns, the first time and whenever JSON brings a key not seen before; for CSV and
    /// TSV with the heading's own text, which goes out ahead of the rows.
    fn columns(&mut self, names: Vec<String>, heading: Option<String>);
    fn record(&mut self, record: Record);
    /// Something in the input that could not be read as its shape; reading goes on.
    fn problem(&mut self, text: String);
    /// The input has ended and every record has been given: `read` says so once it has.
    fn finish(&mut self) {}
    /// Whether to stop reading, asked after each piece (when the view holds all it can).
    fn stop(&self) -> bool {
        false
    }
}

/// Colour and other terminal codes: dropped, from what is shown and from what goes out. These
/// are the control sequences (`ESC [ … final`), the operating system commands (`ESC ] … BEL` or
/// `ESC ] … ESC \`), and the two-character escapes (`ESC @` to `ESC Z`, `ESC \` to `ESC _`).
pub fn plain(text: &str) -> Cow<'_, str> {
    if !text.contains('\x1b') {
        return Cow::Borrowed(text);
    }
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut kept = 0;
    let mut at = 0;
    while at < b.len() {
        if b[at] != 0x1b {
            at += 1;
            continue;
        }
        match escape_len(&b[at..]) {
            Some(len) => {
                out.push_str(&text[kept..at]);
                at += len;
                kept = at;
            }
            None => at += 1,
        }
    }
    out.push_str(&text[kept..]);
    Cow::Owned(out)
}

/// How long the escape at the start of `b` (which begins with ESC) is, if it is one.
fn escape_len(b: &[u8]) -> Option<usize> {
    match b.get(1) {
        Some(b'[') => {
            let mut at = 2;
            while matches!(b.get(at), Some(0x30..=0x3f)) {
                at += 1;
            }
            while matches!(b.get(at), Some(0x20..=0x2f)) {
                at += 1;
            }
            if matches!(b.get(at), Some(0x40..=0x7e)) {
                return Some(at + 1);
            }
            None
        }
        Some(b']') => {
            let mut at = 2;
            while let Some(&c) = b.get(at) {
                if c == 0x07 {
                    return Some(at + 1);
                }
                if c == 0x1b {
                    if b.get(at + 1) == Some(&b'\\') {
                        return Some(at + 2);
                    }
                    break;
                }
                at += 1;
            }
            // Not ended: `ESC ]` alone is a two-character escape.
            Some(2)
        }
        Some(0x40..=0x5a | 0x5c..=0x5f) => Some(2),
        _ => None,
    }
}

/// How many lines, or UTF-16 code units, the shape is read from before records flow.
pub const SAMPLE_LINES: usize = 50;
pub const SAMPLE_BYTES: usize = 64 * 1024;

/// How long a slow input may take before its shape is read from the lines it has sent.
pub const DECIDE_AFTER: Duration = Duration::from_millis(150);

/// How much is read at a time: what Node reads a pipe or a file in, so that the sample the shape
/// is read from is cut where it was.
const PIECE: usize = 64 * 1024;

/// Text in, records out: the shape told from a sample, then each record as its text comes.
pub struct Reader {
    format: Option<Format>,
    buffer: String,
    /// The buffer's length in UTF-16 code units, and its line ends.
    units: usize,
    lines: usize,
    decided: bool,
    ended: bool,
    parser: Option<Parser>,
}

impl Reader {
    pub fn new(format: Option<Format>) -> Reader {
        Reader {
            format,
            buffer: String::new(),
            units: 0,
            lines: 0,
            decided: false,
            ended: false,
            parser: None,
        }
    }

    /// The shape, once it is settled.
    pub fn format(&self) -> Option<Format> {
        if self.decided { self.format } else { None }
    }

    /// Text as it comes.
    pub fn feed(&mut self, text: &str, sink: &mut dyn Sink) {
        if let Some(parser) = &mut self.parser {
            parser.feed(text, sink);
            return;
        }
        self.buffer.push_str(text);
        self.units += utf16_len(text);
        self.lines += text.bytes().filter(|b| *b == b'\n').count();
        if self.format.is_some() || self.units >= SAMPLE_BYTES || self.lines >= SAMPLE_LINES {
            self.decide(sink);
        }
    }

    /// Whether a whole line has come, so that a slow input can be decided on what it has sent.
    pub fn has_line(&self) -> bool {
        self.parser.is_some() || self.lines > 0
    }

    /// Settles the shape on what has come so far, and lets the records flow. Called when the
    /// sample is full, at the end, and by a timer when the input is slow to come.
    pub fn decide(&mut self, sink: &mut dyn Sink) {
        if self.decided {
            return;
        }
        self.decided = true;
        let text = std::mem::take(&mut self.buffer);
        let format = *self.format.get_or_insert_with(|| detect(&text, self.ended));
        sink.format(format);
        let mut parser = Parser::new(format);
        parser.feed(&text, sink);
        self.parser = Some(parser);
    }

    pub fn end(&mut self, sink: &mut dyn Sink) {
        self.ended = true;
        self.decide(sink);
        if let Some(parser) = &mut self.parser {
            parser.end(sink);
        }
    }
}

/// Reads an input to its end, giving the sink its records as their lines come; returns once the
/// input has ended (or the sink has stopped) and every record has been given, or with what kept
/// it from being read, in which case the sink is not finished: the caller says what happened.
///
/// The input is read on a thread of its own, in pieces of 64 KiB as Node reads them, and decoded
/// as Node decodes UTF-8 (a sequence that is not UTF-8 becomes U+FFFD). The shape is told once
/// the sample is full or the input has ended, or `DECIDE_AFTER` after the first line came, so
/// that `tail -f` is not waited on.
pub fn read(
    input: impl Read + Send + 'static,
    given: Option<Format>,
    sink: &mut dyn Sink,
) -> io::Result<()> {
    let (send, pieces) = mpsc::sync_channel::<io::Result<Vec<u8>>>(1);
    std::thread::spawn(move || {
        let mut input = input;
        loop {
            let mut piece = vec![0; PIECE];
            let read = match input.read(&mut piece) {
                Ok(n) => {
                    piece.truncate(n);
                    Ok(piece)
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => Err(e),
            };
            let last = !matches!(&read, Ok(piece) if !piece.is_empty());
            // The reading side has gone (it stopped): so does this one.
            if send.send(read).is_err() || last {
                return;
            }
        }
    });

    let mut reader = Reader::new(given);
    let mut decoder = Decoder::default();
    let mut timer: Option<Instant> = None;
    let mut timed = false;
    let mut stopped = false;
    loop {
        let piece = match timer {
            None => pieces.recv().ok(),
            Some(at) => match pieces.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(piece) => Some(piece),
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    timer = None;
                    reader.decide(sink);
                    continue;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => None,
            },
        };
        let piece = match piece {
            Some(Ok(piece)) if !piece.is_empty() => piece,
            Some(Err(e)) => return Err(e),
            _ => break,
        };
        let text = decoder.decode(&piece);
        if !text.is_empty() {
            reader.feed(&text, sink);
        }
        if !timed && reader.format().is_none() && reader.has_line() {
            timed = true;
            timer = Some(Instant::now() + DECIDE_AFTER);
        }
        if sink.stop() {
            stopped = true;
            break;
        }
    }
    // Stopped, what was left unread is let go, a character cut short among it.
    let rest = decoder.end();
    if !rest.is_empty() && !stopped {
        reader.feed(&rest, sink);
    }
    reader.end(sink);
    sink.finish();
    Ok(())
}

/// UTF-8 decoded piece by piece, a character cut between two pieces kept for the next one.
#[derive(Default)]
struct Decoder {
    pending: Vec<u8>,
}

impl Decoder {
    fn decode(&mut self, piece: &[u8]) -> String {
        let joined;
        let mut bytes = piece;
        if !self.pending.is_empty() {
            let mut all = std::mem::take(&mut self.pending);
            all.extend_from_slice(piece);
            joined = all;
            bytes = &joined;
        }
        let mut out = String::with_capacity(bytes.len());
        loop {
            match std::str::from_utf8(bytes) {
                Ok(text) => {
                    out.push_str(text);
                    return out;
                }
                Err(error) => {
                    let (good, rest) = bytes.split_at(error.valid_up_to());
                    out.push_str(std::str::from_utf8(good).unwrap_or_default());
                    match error.error_len() {
                        Some(len) => {
                            out.push('\u{FFFD}');
                            bytes = &rest[len..];
                        }
                        None => {
                            self.pending = rest.to_vec();
                            return out;
                        }
                    }
                }
            }
        }
    }

    /// What is left at the end: a character cut short is one U+FFFD.
    fn end(&mut self) -> String {
        if self.pending.is_empty() {
            return String::new();
        }
        self.pending.clear();
        "\u{FFFD}".to_string()
    }
}

/// The complete lines of a sample, plain, without the blank ones.
fn sample_lines(text: &str, ended: bool) -> Vec<String> {
    let mut lines: Vec<&str> = text.split('\n').collect();
    if !ended {
        lines.pop();
    }
    lines
        .into_iter()
        .map(|line| plain(line.strip_suffix('\r').unwrap_or(line)).into_owned())
        .filter(|line| !js_trim(line).is_empty())
        .collect()
}

/// The shape of an input, from its first lines; `ended` says whether the text is all there is.
pub fn detect(text: &str, ended: bool) -> Format {
    let lines = sample_lines(text, ended);
    let Some(first) = lines.first().map(|l| js_trim(l)) else {
        return Format::Lines;
    };
    if first.starts_with('{') || first.starts_with('[') {
        let value = parse_json(first);
        if let Some(Value::Object(object)) = &value {
            // One object alone, holding the rows (`{"items": [...]}`, as an API answers): a
            // document.
            if ended && lines.len() == 1 && rows_inside(object).is_some() {
                return Format::Json;
            }
            return Format::Jsonl;
        }
        if let Some(Value::Array(_)) = value {
            return Format::Json;
        }
        let opens = |open: char, then: &[char]| {
            first
                .strip_prefix(open)
                .map(|rest| rest.trim_start_matches(js_space))
                .and_then(|rest| rest.chars().next())
                .is_some_and(|c| then.contains(&c))
        };
        if first == "{" || first == "[" || opens('[', &['{', '[', '"']) || opens('{', &['"']) {
            return Format::Json;
        }
    }
    if lines.len() < 2 {
        return Format::Lines;
    }
    let tabs: Vec<usize> = lines
        .iter()
        .map(|line| line.matches('\t').count())
        .collect();
    if tabs[0] >= 1 && tabs.iter().all(|n| *n == tabs[0]) {
        return Format::Tsv;
    }
    let commas: Vec<usize> = csv_records(&lines)
        .iter()
        .map(|record| csv_fields(record, ',').len())
        .collect();
    if commas[0] >= 2 && commas.iter().all(|n| *n == commas[0]) && !lines[0].contains("  ") {
        return Format::Csv;
    }
    let rest: Vec<&str> = lines[1..].iter().map(String::as_str).collect();
    if looks_like_heading(&lines[0]) && layout_of(&lines[0], &rest).names().len() >= 2 {
        return Format::Columns;
    }
    Format::Lines
}

/// The text split at runs of spaces, as JavaScript's `split(/\s+/)` does: a text that begins or
/// ends with spaces has an empty word there, and an empty text is one empty word.
pub fn split_spaces(text: &str) -> Vec<&str> {
    let mut words = Vec::new();
    let mut from = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        if js_space(c) {
            words.push(&text[from..at]);
            let mut end = at + c.len_utf8();
            while let Some((next, c)) = chars.next_if(|(_, c)| js_space(*c)) {
                end = next + c.len_utf8();
            }
            from = end;
        }
    }
    words.push(&text[from..]);
    words
}

/// How many parts `split(/\s{2,}/)` makes of a text: one more than its runs of two spaces or more.
fn groups(text: &str) -> usize {
    let mut count = 1;
    let mut run = 0;
    for c in text.chars() {
        if js_space(c) {
            run += 1;
        } else {
            if run >= 2 {
                count += 1;
            }
            run = 0;
        }
    }
    if run >= 2 {
        count += 1;
    }
    count
}

/// Whether a character is an upper-case letter, as Unicode's category Lu has it: Rust's
/// `is_uppercase` also counts the Roman numerals and the circled and squared letters.
fn upper_letter(c: char) -> bool {
    c.is_uppercase()
        && !matches!(c as u32,
            0x2160..=0x216F | 0x24B6..=0x24CF | 0x1F130..=0x1F149 | 0x1F150..=0x1F169 | 0x1F170..=0x1F189)
}

/// `NAME   READY   STATUS`, `USER PID %CPU`, `Filesystem Size Used`: words a table is headed with.
fn looks_like_heading(line: &str) -> bool {
    let words = split_spaces(js_trim(line));
    if words.len() < 2 || words.len() > 40 {
        return false;
    }
    if !words[0].chars().next().is_some_and(upper_letter) {
        return false;
    }
    // `SIZE/OFF` (lsof) and `I/O` head columns; `/usr/bin`, `a=1` and `10:00` are values.
    words.iter().all(|word| {
        let b = word.as_bytes();
        let signed = usize::from(matches!(b.first(), Some(b'+' | b'-')));
        let number = b.get(signed).is_some_and(u8::is_ascii_digit);
        let path = matches!(b.first(), Some(b'/' | b'.' | b'~')) || word.contains(['=', ':']);
        !number && !path && utf16_len(word) <= 32
    })
}

/// Lines joined where a quoted field holds a line break: the records of CSV, for telling the shape.
fn csv_records(lines: &[String]) -> Vec<String> {
    let mut records = Vec::new();
    let mut open: Option<String> = None;
    for line in lines {
        let joined = match open.take() {
            None => line.clone(),
            Some(open) => format!("{open}\n{line}"),
        };
        if joined.matches('"').count() % 2 == 0 {
            records.push(joined);
        } else {
            open = Some(joined);
        }
    }
    if let Some(open) = open {
        records.push(open);
    }
    records
}

/// Splits one record of CSV: for telling the shape.
fn csv_fields(line: &str, delimiter: char) -> Vec<String> {
    let mut fields = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            if c == '"' && chars.peek() == Some(&'"') {
                field.push('"');
                chars.next();
            } else if c == '"' {
                quoted = false;
            } else {
                field.push(c);
            }
        } else if c == '"' && field.is_empty() {
            quoted = true;
        } else if c == delimiter {
            fields.push(std::mem::take(&mut field));
        } else {
            field.push(c);
        }
    }
    fields.push(field);
    fields
}

/// A text as UTF-16 code units, which is how places in a line are counted.
fn units(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

/// Whether a code unit is a space to `\s`; half of a surrogate pair is not.
fn unit_space(unit: u16) -> bool {
    char::from_u32(u32::from(unit)).is_some_and(js_space)
}

/// Where the columns of a table lined up with spaces begin: at each place where every line, the
/// heading among them, has a space just before and the heading a word, so that a value with
/// spaces of its own (`Up 2 hours`) stays one cell. The last column takes the rest of each line
/// (`COMMAND` in `ps`). Places are in UTF-16 code units.
#[cfg(test)]
pub fn column_starts(heading: &str, lines: &[&str]) -> Vec<usize> {
    let lines: Vec<Vec<u16>> = lines.iter().map(|line| units(line)).collect();
    starts_of(&units(heading), &lines)
}

fn starts_of(heading: &[u16], lines: &[Vec<u16>]) -> Vec<usize> {
    let words: Vec<usize> = (0..heading.len())
        .filter(|&at| !unit_space(heading[at]) && (at == 0 || unit_space(heading[at - 1])))
        .collect();
    let (Some(&first), Some(&last)) = (words.first(), words.last()) else {
        return Vec::new();
    };
    let blank = |line: &[u16], at: usize| line.get(at).is_none_or(|u| *u == 32);
    let gap = |at: usize| blank(heading, at) && lines.iter().all(|line| blank(line, at));
    let mut starts = vec![first];
    for at in first + 1..=last {
        if gap(at - 1) && !gap(at) {
            starts.push(at);
        }
    }
    // A column whose values are wider than its heading (a right-aligned PID) begins before the
    // heading's word: the first column still begins at 0.
    starts[0] = 0;
    starts
}

/// How a table lined up with spaces is cut into columns.
///
/// Most commands keep their columns lined up under the headings (`docker ps`, `kubectl get`,
/// `df`), and their values may hold spaces (`Up 2 hours`): those are cut where the columns are.
/// Some let a wide value push the rest of its line to the right — `ps` on macOS does, with a
/// twelve-digit VSZ — so that no column lines up after it; when the places find fewer columns
/// than the heading has groups of words, and every line has a word for each heading, the line is
/// split at its spaces instead, the last column taking the rest of it (`COMMAND`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Layout {
    Places {
        starts: Vec<usize>,
        names: Vec<String>,
    },
    Words {
        count: usize,
        names: Vec<String>,
    },
}

impl Layout {
    pub fn names(&self) -> &[String] {
        match self {
            Layout::Places { names, .. } | Layout::Words { names, .. } => names,
        }
    }

    /// A line cut into its cells.
    pub fn cells(&self, line: &str) -> Vec<String> {
        match self {
            Layout::Places { starts, .. } => cut_columns(line, starts),
            Layout::Words { count, .. } => split_words(line, *count),
        }
    }
}

pub fn layout_of(heading: &str, lines: &[&str]) -> Layout {
    let line_units: Vec<Vec<u16>> = lines.iter().map(|line| units(line)).collect();
    let heading_units = units(heading);
    let starts = starts_of(&heading_units, &line_units);
    let names = names_of(&cut_units(&heading_units, &starts));
    let trimmed = js_trim(heading);
    let words = split_spaces(trimmed);
    if starts.len() >= groups(trimmed) || words.len() < 2 {
        return Layout::Places { starts, names };
    }
    let fits = lines
        .iter()
        .all(|line| split_spaces(js_trim(line)).len() >= words.len());
    if !fits {
        return Layout::Places { starts, names };
    }
    let words: Vec<String> = words.into_iter().map(str::to_string).collect();
    Layout::Words {
        count: words.len(),
        names: names_of(&words),
    }
}

/// A line split at its spaces into `count` cells, the last taking the rest of the line.
pub fn split_words(line: &str, count: usize) -> Vec<String> {
    let mut cells = Vec::new();
    let mut rest = js_trim(line);
    while cells.len() + 1 < count && !rest.is_empty() {
        let end = rest.find(js_space).unwrap_or(rest.len());
        cells.push(rest[..end].to_string());
        rest = rest[end..].trim_start_matches(js_space);
    }
    if !rest.is_empty() {
        cells.push(rest.to_string());
    }
    cells
}

/// A line cut at the starts, each boundary moved to the nearest space when a word crosses it.
pub fn cut_columns(line: &str, starts: &[usize]) -> Vec<String> {
    cut_units(&units(line), starts)
}

fn cut_units(line: &[u16], starts: &[usize]) -> Vec<String> {
    let space = |at: usize| line.get(at) == Some(&32);
    let mut bounds = starts.to_vec();
    for i in 1..bounds.len() {
        let at = bounds[i];
        if at >= line.len() || (at > 0 && space(at - 1)) || space(at) {
            continue;
        }
        let floor = bounds[i - 1].saturating_add(1);
        // Where the nearest space is on either side, as how far the boundary moves.
        let to_left = (floor..at)
            .rev()
            .find(|&left| space(left))
            .map(|left| (at - left - 1, left));
        let to_right = (at..line.len())
            .find(|&right| space(right))
            .map(|right| (right - at, right));
        bounds[i] = match (to_left, to_right) {
            (None, None) => continue,
            (Some((l, left)), Some((r, _))) if l <= r => left + 1,
            (Some((_, left)), None) => left + 1,
            (_, Some((_, right))) => right + 1,
        };
    }
    (0..bounds.len())
        .map(|i| {
            let from = bounds[i].min(line.len());
            let to = bounds
                .get(i + 1)
                .copied()
                .unwrap_or(line.len())
                .min(line.len());
            let cell = if from < to {
                String::from_utf16_lossy(&line[from..to])
            } else {
                String::new()
            };
            js_trim(&cell).to_string()
        })
        .collect()
}

/// Column names from a heading, unique and never empty.
pub fn names_of(fields: &[String]) -> Vec<String> {
    let mut seen: HashMap<String, usize> = HashMap::new();
    fields
        .iter()
        .enumerate()
        .map(|(at, field)| {
            let trimmed = js_trim(field);
            let base = if trimmed.is_empty() {
                format!("column {}", at + 1)
            } else {
                trimmed.to_string()
            };
            let n = seen.entry(base.to_lowercase()).or_insert(0);
            *n += 1;
            if *n == 1 { base } else { format!("{base} {n}") }
        })
        .collect()
}

enum Parser {
    Lines {
        lines: LineParser,
        started: bool,
    },
    Columns(ColumnsParser),
    Delimited(DelimitedParser),
    JsonLines {
        lines: LineParser,
        keys: Keys,
        bad: usize,
    },
    Json(String),
}

impl Parser {
    fn new(format: Format) -> Parser {
        match format {
            Format::Lines => Parser::Lines {
                lines: LineParser::default(),
                started: false,
            },
            Format::Columns => Parser::Columns(ColumnsParser::default()),
            Format::Csv => Parser::Delimited(DelimitedParser::new(',')),
            Format::Tsv => Parser::Delimited(DelimitedParser::new('\t')),
            Format::Jsonl => Parser::JsonLines {
                lines: LineParser::default(),
                keys: Keys::default(),
                bad: 0,
            },
            Format::Json => Parser::Json(String::new()),
        }
    }

    fn feed(&mut self, text: &str, sink: &mut dyn Sink) {
        match self {
            Parser::Lines { lines, started } => {
                start_lines(started, sink);
                for line in lines.feed(text) {
                    sink.record(Record {
                        cells: vec![line.clone()],
                        raw: line,
                        value: None,
                    });
                }
            }
            Parser::Columns(parser) => parser.feed(text, sink),
            Parser::Delimited(parser) => parser.feed(text, sink),
            Parser::JsonLines { lines, keys, bad } => {
                for line in lines.feed(text) {
                    json_line(line, keys, bad, sink);
                }
            }
            Parser::Json(all) => all.push_str(text),
        }
    }

    fn end(&mut self, sink: &mut dyn Sink) {
        match self {
            Parser::Lines { lines, started } => {
                start_lines(started, sink);
                if let Some(line) = lines.end() {
                    sink.record(Record {
                        cells: vec![line.clone()],
                        raw: line,
                        value: None,
                    });
                }
            }
            Parser::Columns(parser) => parser.end(sink),
            Parser::Delimited(parser) => parser.end(sink),
            Parser::JsonLines { lines, keys, bad } => {
                if let Some(line) = lines.end() {
                    json_line(line, keys, bad, sink);
                }
            }
            Parser::Json(all) => json_document(&std::mem::take(all), sink),
        }
    }
}

/// Lines have one column, said before the first of them.
fn start_lines(started: &mut bool, sink: &mut dyn Sink) {
    if !*started {
        *started = true;
        sink.columns(vec!["line".to_string()], None);
    }
}

/// Whole lines, plain, without their endings; blank lines are skipped.
#[derive(Default)]
struct LineParser {
    rest: String,
}

impl LineParser {
    /// The lines this piece completes.
    fn feed(&mut self, text: &str) -> Vec<String> {
        let mut lines = Vec::new();
        let mut pieces = text.split('\n');
        let Some(first) = pieces.next() else {
            return lines;
        };
        self.rest.push_str(first);
        for piece in pieces {
            let line = std::mem::replace(&mut self.rest, piece.to_string());
            lines.extend(clean(&line));
        }
        lines
    }

    fn end(&mut self) -> Option<String> {
        let rest = std::mem::take(&mut self.rest);
        if rest.is_empty() { None } else { clean(&rest) }
    }
}

/// A line without its CR and colour codes, or none when that leaves it blank.
fn clean(line: &str) -> Option<String> {
    let clean = plain(line.strip_suffix('\r').unwrap_or(line)).into_owned();
    if js_trim(&clean).is_empty() {
        None
    } else {
        Some(clean)
    }
}

#[derive(Default)]
struct ColumnsParser {
    lines: LineParser,
    heading: Option<String>,
    waiting: Vec<String>,
    layout: Option<Layout>,
}

impl ColumnsParser {
    fn feed(&mut self, text: &str, sink: &mut dyn Sink) {
        for line in self.lines.feed(text) {
            self.line(line, sink);
        }
        // The columns are read from what this first piece brought: the sample the shape was told
        // from, or the first lines of a file whose shape was given.
        self.settle(false, sink);
    }

    fn end(&mut self, sink: &mut dyn Sink) {
        if let Some(line) = self.lines.end() {
            self.line(line, sink);
        }
        self.settle(true, sink);
    }

    fn line(&mut self, line: String, sink: &mut dyn Sink) {
        if self.heading.is_none() {
            self.heading = Some(line);
        } else if let Some(layout) = &self.layout {
            sink.record(Record {
                cells: layout.cells(&line),
                raw: line,
                value: None,
            });
        } else {
            self.waiting.push(line);
        }
    }

    fn settle(&mut self, ended: bool, sink: &mut dyn Sink) {
        let Some(heading) = &self.heading else { return };
        if self.layout.is_some() {
            return;
        }
        // A heading alone tells no column from a space inside a heading (`IMAGE ID`): wait for a
        // line.
        if self.waiting.is_empty() && !ended {
            return;
        }
        let first: Vec<&str> = self.waiting.iter().take(200).map(String::as_str).collect();
        let layout = layout_of(heading, &first);
        sink.columns(layout.names().to_vec(), None);
        for line in std::mem::take(&mut self.waiting) {
            sink.record(Record {
                cells: layout.cells(&line),
                raw: line,
                value: None,
            });
        }
        self.layout = Some(layout);
    }
}

/// CSV or TSV: the first record is the heading; quoted fields may hold line breaks.
struct DelimitedParser {
    delimiter: char,
    field: String,
    cells: Vec<String>,
    raw: String,
    quoted: bool,
    /// A quote just closed inside a quoted field: the next quote makes it a literal one.
    closing: bool,
    heading: bool,
}

impl DelimitedParser {
    fn new(delimiter: char) -> DelimitedParser {
        DelimitedParser {
            delimiter,
            field: String::new(),
            cells: Vec::new(),
            raw: String::new(),
            quoted: false,
            closing: false,
            heading: true,
        }
    }

    fn feed(&mut self, text: &str, sink: &mut dyn Sink) {
        for c in text.chars() {
            self.char(c, sink);
        }
    }

    fn end(&mut self, sink: &mut dyn Sink) {
        if !js_trim(&self.raw).is_empty() || !self.cells.is_empty() {
            self.record(sink);
        }
    }

    fn char(&mut self, c: char, sink: &mut dyn Sink) {
        if c == '\n' && !self.quoted {
            self.record(sink);
            return;
        }
        self.raw.push(c);
        if self.quoted {
            if c == '"' {
                self.quoted = false;
                self.closing = true;
            } else {
                self.field.push(c);
            }
            return;
        }
        if self.closing && c == '"' {
            self.field.push('"');
            self.quoted = true;
            self.closing = false;
            return;
        }
        self.closing = false;
        if c == '"' && self.field.is_empty() {
            self.quoted = true;
        } else if c == self.delimiter {
            self.cells.push(std::mem::take(&mut self.field));
        } else if c != '\r' {
            self.field.push(c);
        }
    }

    fn record(&mut self, sink: &mut dyn Sink) {
        let raw = std::mem::take(&mut self.raw);
        let raw = plain(raw.strip_suffix('\r').unwrap_or(&raw)).into_owned();
        self.cells.push(std::mem::take(&mut self.field));
        let cells: Vec<String> = std::mem::take(&mut self.cells)
            .iter()
            .map(|c| plain(c).into_owned())
            .collect();
        self.closing = false;
        if js_trim(&raw).is_empty() {
            return;
        }
        if self.heading {
            self.heading = false;
            sink.columns(names_of(&cells), Some(raw));
        } else {
            sink.record(Record {
                cells,
                raw,
                value: None,
            });
        }
    }
}

/// The columns of JSON objects: their keys, in the order they were first seen.
#[derive(Default)]
struct Keys {
    names: Vec<String>,
    at: HashMap<String, usize>,
}

impl Keys {
    /// The cells of a value, telling the sink of keys it brings.
    fn cells(&mut self, value: &Value, sink: &mut dyn Sink) -> Vec<String> {
        let mut cells: Vec<Option<String>> = Vec::new();
        let mut put = |at: usize, text: String| {
            if cells.len() <= at {
                cells.resize(at + 1, None);
            }
            cells[at] = Some(text);
        };
        match value {
            Value::Object(object) => {
                self.add(object.keys(), sink);
                for (key, item) in object {
                    if let Some(&at) = self.at.get(key) {
                        put(at, text_of(item));
                    }
                }
            }
            _ => {
                self.add(std::iter::once(&"value".to_string()), sink);
                if let Some(&at) = self.at.get("value") {
                    put(at, text_of(value));
                }
            }
        }
        cells.into_iter().map(Option::unwrap_or_default).collect()
    }

    fn add<'a>(&mut self, keys: impl Iterator<Item = &'a String>, sink: &mut dyn Sink) {
        let mut added = false;
        for key in keys {
            if self.at.contains_key(key) {
                continue;
            }
            self.at.insert(key.clone(), self.names.len());
            self.names.push(key.clone());
            added = true;
        }
        if added {
            sink.columns(self.names.clone(), None);
        }
    }
}

/// A value as a cell shows it: text as itself, a number or a truth as JavaScript writes it,
/// nothing for null, and anything else as JSON.
pub fn text_of(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        Value::Bool(truth) => truth.to_string(),
        Value::Number(n) => js_number(n.as_f64().unwrap_or(f64::NAN)),
        _ => stringify(value),
    }
}

fn json_line(line: String, keys: &mut Keys, bad: &mut usize, sink: &mut dyn Sink) {
    let Some(value) = parse_json(&line) else {
        *bad += 1;
        // Told once, then counted: a log with a line of text in it should not drown the view.
        if *bad == 1 || (*bad).is_multiple_of(1000) {
            let lines = if *bad == 1 {
                "A line is".to_string()
            } else {
                format!("{bad} lines are")
            };
            sink.problem(format!("{lines} not JSON"));
        }
        return;
    };
    let cells = keys.cells(&value, sink);
    sink.record(Record {
        cells,
        raw: line,
        value: Some(value),
    });
}

/// One JSON document, read whole: an array is its elements, `{"items": [...]}` its items.
fn json_document(text: &str, sink: &mut dyn Sink) {
    let Some(value) = parse_json(text) else {
        sink.problem("The input is not one JSON document".to_string());
        return;
    };
    let mut keys = Keys::default();
    for item in elements_of(value) {
        let cells = keys.cells(&item, sink);
        sink.record(Record {
            cells,
            raw: stringify(&item),
            value: Some(item),
        });
    }
    if keys.names.is_empty() {
        sink.columns(vec!["value".to_string()], None);
    }
}

/// The key of the one array of objects an object holds, as an API's answer holds its rows.
fn rows_inside(object: &Map<String, Value>) -> Option<&String> {
    let mut arrays = object.iter().filter(|(_, item)| match item {
        Value::Array(items) => !items.is_empty() && items.iter().all(Value::is_object),
        _ => false,
    });
    let first = arrays.next()?;
    if arrays.next().is_some() {
        None
    } else {
        Some(first.0)
    }
}

/// The rows of a JSON document: an array's elements, the one array of objects an object holds,
/// or itself.
fn elements_of(value: Value) -> Vec<Value> {
    match value {
        Value::Array(items) => items,
        Value::Object(mut object) => match rows_inside(&object).cloned() {
            Some(key) => match object.get_mut(&key).map(Value::take) {
                Some(Value::Array(items)) => items,
                _ => Vec::new(),
            },
            None => vec![Value::Object(object)],
        },
        value => vec![value],
    }
}

/// JSON read as JavaScript's `JSON.parse` reads it, or none when it is not JSON.
///
/// - numbers are JavaScript's numbers: 64-bit floats, a whole one under 2⁵³ kept as an integer
///   (`1.0` is `1`); one too large to hold (`1e400`) is null, where JavaScript has Infinity;
/// - keys that are array indices (`"0"`, `"42"`) come first, in order, as in a JavaScript object;
///   a key given twice keeps its first place and its last value;
/// - a `\u` escape of half a surrogate pair is U+FFFD, which is what JavaScript writes such a
///   text out as in UTF-8;
/// - nesting deeper than 1000 is not read (JavaScript could read it, but not write it again).
pub fn parse_json(text: &str) -> Option<Value> {
    let mut parser = JsonReader {
        b: text.as_bytes(),
        text,
        at: 0,
    };
    parser.space();
    let value = parser.value(0)?;
    parser.space();
    (parser.at == parser.b.len()).then_some(value)
}

struct JsonReader<'a> {
    b: &'a [u8],
    text: &'a str,
    at: usize,
}

const DEEPEST: usize = 1000;

impl JsonReader<'_> {
    fn space(&mut self) {
        while matches!(self.b.get(self.at), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn word(&mut self, word: &str, value: Value) -> Option<Value> {
        if self.b[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            Some(value)
        } else {
            None
        }
    }

    fn value(&mut self, depth: usize) -> Option<Value> {
        if depth > DEEPEST {
            return None;
        }
        match *self.b.get(self.at)? {
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'"' => self.string().map(Value::String),
            b't' => self.word("true", Value::Bool(true)),
            b'f' => self.word("false", Value::Bool(false)),
            b'n' => self.word("null", Value::Null),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn object(&mut self, depth: usize) -> Option<Value> {
        self.at += 1;
        let mut object = Map::new();
        self.space();
        if self.b.get(self.at) == Some(&b'}') {
            self.at += 1;
            return Some(Value::Object(object));
        }
        loop {
            self.space();
            if self.b.get(self.at) != Some(&b'"') {
                return None;
            }
            let key = self.string()?;
            self.space();
            if self.b.get(self.at) != Some(&b':') {
                return None;
            }
            self.at += 1;
            self.space();
            let value = self.value(depth + 1)?;
            object.insert(key, value);
            self.space();
            match self.b.get(self.at)? {
                b',' => self.at += 1,
                b'}' => {
                    self.at += 1;
                    return Some(Value::Object(js_ordered(object)));
                }
                _ => return None,
            }
        }
    }

    fn array(&mut self, depth: usize) -> Option<Value> {
        self.at += 1;
        let mut items = Vec::new();
        self.space();
        if self.b.get(self.at) == Some(&b']') {
            self.at += 1;
            return Some(Value::Array(items));
        }
        loop {
            self.space();
            items.push(self.value(depth + 1)?);
            self.space();
            match self.b.get(self.at)? {
                b',' => self.at += 1,
                b']' => {
                    self.at += 1;
                    return Some(Value::Array(items));
                }
                _ => return None,
            }
        }
    }

    fn hex4(&mut self) -> Option<u32> {
        let digits = self.text.get(self.at..self.at + 4)?;
        if !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        self.at += 4;
        u32::from_str_radix(digits, 16).ok()
    }

    fn string(&mut self) -> Option<String> {
        self.at += 1;
        let mut out = String::new();
        loop {
            let from = self.at;
            while let Some(&c) = self.b.get(self.at) {
                if c == b'"' || c == b'\\' || c < 0x20 {
                    break;
                }
                self.at += 1;
            }
            out.push_str(&self.text[from..self.at]);
            match *self.b.get(self.at)? {
                b'"' => {
                    self.at += 1;
                    return Some(out);
                }
                b'\\' => {
                    self.at += 1;
                    let escape = *self.b.get(self.at)?;
                    self.at += 1;
                    match escape {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let unit = self.hex4()?;
                            out.push(self.surrogates(unit));
                        }
                        _ => return None,
                    }
                }
                // A control character must be escaped.
                _ => return None,
            }
        }
    }

    /// The character a `\u` escape is, with the escape of a pair's second half after it.
    fn surrogates(&mut self, unit: u32) -> char {
        if (0xD800..0xDC00).contains(&unit) && self.b[self.at..].starts_with(b"\\u") {
            let back = self.at;
            self.at += 2;
            if let Some(low) = self.hex4().filter(|low| (0xDC00..0xE000).contains(low)) {
                let c = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                return char::from_u32(c).unwrap_or('\u{FFFD}');
            }
            self.at = back;
        }
        char::from_u32(unit).unwrap_or('\u{FFFD}')
    }

    fn number(&mut self) -> Option<Value> {
        let from = self.at;
        if self.b.get(self.at) == Some(&b'-') {
            self.at += 1;
        }
        let digits = |r: &mut Self| {
            let n = r.b[r.at..]
                .iter()
                .take_while(|b| b.is_ascii_digit())
                .count();
            r.at += n;
            n
        };
        match self.b.get(self.at) {
            Some(b'0') => self.at += 1,
            Some(b'1'..=b'9') => {
                digits(self);
            }
            _ => return None,
        }
        if self.b.get(self.at) == Some(&b'.') {
            self.at += 1;
            if digits(self) == 0 {
                return None;
            }
        }
        if matches!(self.b.get(self.at), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.b.get(self.at), Some(b'+' | b'-')) {
                self.at += 1;
            }
            if digits(self) == 0 {
                return None;
            }
        }
        let n: f64 = self.text[from..self.at].parse().ok()?;
        Some(js_value(n))
    }
}

/// A JavaScript number as a JSON value: whole and under 2⁵³ as an integer, so that it is written
/// without a point, and otherwise as it is; one that is not finite is null, as JSON writes it.
pub fn js_value(n: f64) -> Value {
    if n.fract() == 0.0 && n.abs() < 9_007_199_254_740_992.0 {
        return Value::Number(Number::from(n as i64));
    }
    Number::from_f64(n).map_or(Value::Null, Value::Number)
}

/// Whether a key is an array index, which a JavaScript object keeps ahead of its other keys.
fn array_index(key: &str) -> Option<u32> {
    let b = key.as_bytes();
    if b.is_empty()
        || b.len() > 10
        || !b.iter().all(u8::is_ascii_digit)
        || (b[0] == b'0' && b.len() > 1)
    {
        return None;
    }
    key.parse::<u64>()
        .ok()
        .filter(|n| *n < 4_294_967_295)
        .map(|n| n as u32)
}

/// An object's keys in the order JavaScript keeps them: array indices first, from the least, then
/// the others in the order they came.
pub fn js_ordered(object: Map<String, Value>) -> Map<String, Value> {
    if !object.keys().any(|key| array_index(key).is_some()) {
        return object;
    }
    let mut indices = Vec::new();
    let mut others = Vec::new();
    for (key, value) in object {
        match array_index(&key) {
            Some(n) => indices.push((n, key, value)),
            None => others.push((key, value)),
        }
    }
    indices.sort_by_key(|(n, _, _)| *n);
    indices
        .into_iter()
        .map(|(_, key, value)| (key, value))
        .chain(others)
        .collect()
}

/// A value written as JavaScript's `JSON.stringify` writes it: compact, keys in their order,
/// numbers as JavaScript writes them.
pub fn stringify(value: &Value) -> String {
    let mut out = String::new();
    write_json(value, &mut out);
    out
}

fn write_json(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(truth) => out.push_str(if *truth { "true" } else { "false" }),
        Value::Number(n) => match n.as_f64().filter(|n| n.is_finite()) {
            Some(n) => out.push_str(&js_number(n)),
            None => out.push_str("null"),
        },
        Value::String(text) => quote_into(text, out),
        Value::Array(items) => {
            out.push('[');
            for (at, item) in items.iter().enumerate() {
                if at > 0 {
                    out.push(',');
                }
                write_json(item, out);
            }
            out.push(']');
        }
        Value::Object(object) => {
            out.push('{');
            for (at, (key, item)) in object.iter().enumerate() {
                if at > 0 {
                    out.push(',');
                }
                quote_into(key, out);
                out.push(':');
                write_json(item, out);
            }
            out.push('}');
        }
    }
}

/// A text as JSON writes it, in double quotes: `JSON.stringify` of a string.
pub fn quote_json(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    quote_into(text, &mut out);
    out
}

fn quote_into(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
#[path = "input_tests.rs"]
mod tests;
