//! What goes out on stdout for the rows chosen. One function writes it, and the view's picture of
//! what will go out is drawn by the same function, so that the two never differ.
//!
//! In the input's shape, a row goes out as the text it was read from: lines and columns as their
//! lines (a table's heading stays behind, so that `| xargs` is given only rows), CSV and TSV after
//! their heading, JSON lines as their lines, and a JSON document as an array of the elements
//! chosen. `--field`, `--format` and `--output` shape it otherwise.

use serde_json::{Map, Value};

use crate::input::{Format, Record, js_ordered, quote_json, split_spaces, stringify};
use crate::query::column_named;
use crate::values::js_trim;

/// What `--output` converts to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum As {
    Csv,
    Tsv,
    Json,
    Jsonl,
}

impl As {
    pub fn name(self) -> &'static str {
        match self {
            As::Csv => "csv",
            As::Tsv => "tsv",
            As::Json => "json",
            As::Jsonl => "jsonl",
        }
    }

    pub fn from_name(name: &str) -> Option<As> {
        [As::Csv, As::Tsv, As::Json, As::Jsonl]
            .into_iter()
            .find(|a| a.name() == name)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Shape {
    Input,
    Fields(Vec<String>),
    Template(String),
    As(As),
}

/// What the rows were read as: their shape, their columns, and a CSV or TSV heading's own text.
#[derive(Clone, Copy, Debug)]
pub struct Source<'a> {
    pub format: Option<Format>,
    pub names: &'a [String],
    pub heading: Option<&'a str>,
}

/// Whether a name is digits alone, and the number they make (`usize::MAX` for one too large to
/// hold, which no column or word is at).
fn place(name: &str) -> Option<usize> {
    if name.is_empty() || !name.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(name.parse().unwrap_or(usize::MAX))
}

/// A part of a row, by the name `--field`, `--format` and `--preview` give it: a column by its
/// heading, `2` the second column, and `` (as in `{}`) the row as it was read. In lines, which
/// have one column, `2` is the line's second word, as fzf and awk count: `git log --oneline |
/// pickpen --field 1` writes the hashes. A column whose heading is a number is that column.
pub fn part_of(record: &Record, name: &str, source: &Source) -> Option<String> {
    let names = source.names;
    if name.is_empty() {
        return Some(record.raw.clone());
    }
    if let Some(at) = column_named(names, name) {
        return Some(record.cells.get(at).cloned().unwrap_or_default());
    }
    let n = place(name).filter(|n| *n > 0)?;
    if source.format == Some(Format::Lines) {
        let words: Vec<&str> = split_spaces(js_trim(&record.raw));
        return Some(words.get(n - 1).map_or(String::new(), |w| w.to_string()));
    }
    Some(record.cells.get(n - 1).cloned().unwrap_or_default())
}

/// Whether `part_of` knows the name with these columns.
pub fn knows(name: &str, names: &[String]) -> bool {
    name.is_empty() || column_named(names, name).is_some() || place(name).is_some_and(|n| n > 0)
}

/// The names a template's `{…}` give, in order: `{` then anything but braces, then `}`.
fn placeholders(template: &str) -> Vec<(usize, usize)> {
    let b = template.as_bytes();
    let mut found = Vec::new();
    let mut at = 0;
    while at < b.len() {
        if b[at] == b'{'
            && let Some(len) = b[at + 1..].iter().position(|c| *c == b'{' || *c == b'}')
            && b[at + 1 + len] == b'}'
        {
            found.push((at, at + 2 + len));
            at += 2 + len;
            continue;
        }
        at += 1;
    }
    found
}

/// Why the shape cannot be written with these columns, or none when it can.
pub fn problem_of(shape: &Shape, names: &[String]) -> Option<String> {
    let missing = |name: &str| format!("There is no column named {}", quote_json(name));
    match shape {
        Shape::Fields(fields) => fields
            .iter()
            .find(|name| !knows(name, names))
            .map(|n| missing(n)),
        Shape::Template(template) => placeholders(template)
            .into_iter()
            .map(|(from, to)| &template[from + 1..to - 1])
            .find(|name| !knows(name, names))
            .map(missing),
        _ => None,
    }
}

fn csv_cell(cell: &str) -> String {
    if cell.contains(['"', ',', '\n', '\r']) || cell != js_trim(cell) {
        format!("\"{}\"", cell.replace('"', "\"\""))
    } else {
        cell.to_string()
    }
}

fn tsv_cell(cell: &str) -> String {
    cell.replace(['\t', '\n', '\r'], " ")
}

fn cell_of(record: &Record, at: usize) -> &str {
    record.cells.get(at).map_or("", String::as_str)
}

fn object_of(record: &Record, names: &[String]) -> Value {
    if let Some(value) = &record.value {
        return value.clone();
    }
    let mut object = Map::new();
    for (at, name) in names.iter().enumerate() {
        object.insert(name.clone(), Value::String(cell_of(record, at).to_string()));
    }
    Value::Object(js_ordered(object))
}

/// Where the output ends a line: every line it writes ends with one.
fn lines(items: impl IntoIterator<Item = String>) -> String {
    let mut out = String::new();
    for item in items {
        out.push_str(&item);
        out.push('\n');
    }
    out
}

/// The heading CSV or TSV input goes out with: its own text, or its names joined.
fn heading_of(source: &Source, format: Format) -> String {
    match source.heading {
        Some(heading) => heading.to_string(),
        None => source
            .names
            .join(if format == Format::Csv { "," } else { "\t" }),
    }
}

/// The rows as they go out; nothing at all for no rows.
pub fn render(records: &[&Record], shape: &Shape, source: &Source) -> String {
    if records.is_empty() {
        return String::new();
    }
    match shape {
        Shape::Fields(fields) => lines(records.iter().map(|r| {
            let parts: Vec<String> = fields
                .iter()
                .map(|name| part_of(r, name, source).unwrap_or_default())
                .collect();
            parts.join("\t")
        })),
        Shape::Template(template) => {
            lines(records.iter().map(|r| fill_template(template, r, source)))
        }
        Shape::As(format) => render_as(*format, records, source.names),
        Shape::Input => match source.format {
            Some(format @ (Format::Csv | Format::Tsv)) => {
                lines([heading_of(source, format)]) + &lines(records.iter().map(|r| r.raw.clone()))
            }
            Some(Format::Json) => {
                let items: Vec<String> = records.iter().map(|r| format!("  {}", r.raw)).collect();
                format!("[\n{}\n]\n", items.join(",\n"))
            }
            _ => lines(records.iter().map(|r| r.raw.clone())),
        },
    }
}

fn render_as(format: As, records: &[&Record], names: &[String]) -> String {
    let row = |r: &Record, cell: fn(&str) -> String, by: &str| {
        let cells: Vec<String> = (0..names.len()).map(|at| cell(cell_of(r, at))).collect();
        cells.join(by)
    };
    match format {
        As::Csv => {
            let heading: Vec<String> = names.iter().map(|n| csv_cell(n)).collect();
            lines(
                std::iter::once(heading.join(","))
                    .chain(records.iter().map(|r| row(r, csv_cell, ","))),
            )
        }
        As::Tsv => {
            let heading: Vec<String> = names.iter().map(|n| tsv_cell(n)).collect();
            lines(
                std::iter::once(heading.join("\t"))
                    .chain(records.iter().map(|r| row(r, tsv_cell, "\t"))),
            )
        }
        As::Jsonl => lines(records.iter().map(|r| stringify(&object_of(r, names)))),
        As::Json => {
            let items: Vec<String> = records
                .iter()
                .map(|r| format!("  {}", stringify(&object_of(r, names))))
                .collect();
            format!("[\n{}\n]\n", items.join(",\n"))
        }
    }
}

/// `{NAME}` is that column, `{2}` the second, `{}` the row as it was read (`part_of`).
pub fn fill_template(template: &str, record: &Record, source: &Source) -> String {
    let mut out = String::new();
    let mut kept = 0;
    for (from, to) in placeholders(template) {
        out.push_str(&template[kept..from]);
        out.push_str(&part_of(record, &template[from + 1..to - 1], source).unwrap_or_default());
        kept = to;
    }
    out.push_str(&template[kept..]);
    out
}

/// Whether rows can be written one by one as they come, rather than all at the end.
pub fn streams(shape: &Shape, format: Option<Format>) -> bool {
    match shape {
        Shape::As(to) => *to != As::Json,
        Shape::Input => format != Some(Format::Json),
        _ => true,
    }
}

/// What goes ahead of the first row when rows are written one by one.
pub fn head(shape: &Shape, source: &Source) -> String {
    match (shape, source.format) {
        (Shape::As(As::Csv), _) => {
            let names: Vec<String> = source.names.iter().map(|n| csv_cell(n)).collect();
            lines([names.join(",")])
        }
        (Shape::As(As::Tsv), _) => {
            let names: Vec<String> = source.names.iter().map(|n| tsv_cell(n)).collect();
            lines([names.join("\t")])
        }
        (Shape::Input, Some(format @ (Format::Csv | Format::Tsv))) => {
            lines([heading_of(source, format)])
        }
        _ => String::new(),
    }
}

/// One row, as it goes out after `head` when rows are written one by one.
pub fn one(record: &Record, shape: &Shape, source: &Source) -> String {
    match (shape, source.format) {
        (Shape::As(As::Csv | As::Tsv), _) => {
            let all = render(&[record], shape, source);
            let rest: Vec<&str> = all.split('\n').skip(1).collect();
            rest.join("\n")
        }
        (Shape::Input, Some(Format::Csv | Format::Tsv)) => format!("{}\n", record.raw),
        _ => render(&[record], shape, source),
    }
}

#[cfg(test)]
#[path = "output_tests.rs"]
mod tests;
