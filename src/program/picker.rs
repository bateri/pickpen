//! What the program holds while the view is open: every row read, the columns, and what the person
//! sees of them — the query, the order, the rows it shows in that order, and the marks. The view
//! holds where the person is (the cursor, what is open) and asks for the rows in sight; everything
//! that needs all the rows is done here, where they are.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::time::Instant;

use serde_json::{Value, json};

use crate::input::{Format, Record};
use crate::output::Source;
use crate::query::{self, Query, SortKey, Term};
use crate::values::{self, Kind, quantity};

/// The most rows the program reads. Reading stops there, and the view says so: a person does not
/// look through more, and a million rows are a few hundred megabytes held.
pub const MAX_ROWS: usize = 1_000_000;

/// The longest cell the view is given in a window; a longer one is cut (the panel, a copy and the
/// output have it whole).
pub const MAX_CELL: usize = 2_000;

/// How many rows a column's kind and width are read from.
const KIND_ROWS: usize = 500;
const WIDTH_ROWS: usize = 300;

/// What a person sees of the rows: the order they are shown in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Order {
    pub column: usize,
    pub descending: bool,
}

/// The chart of a column as the panel last drew it: what a drag across it is read against.
#[derive(Clone, Copy, Debug)]
struct Scale {
    kind: Kind,
    low: f64,
    span: f64,
    log: bool,
}

impl Scale {
    fn scale(&self, value: f64) -> f64 {
        if self.log { value.ln() } else { value }
    }

    fn place(&self, value: f64) -> f64 {
        (self.scale(value) - self.low) / self.span
    }

    fn value_at(&self, fraction: f64) -> f64 {
        let v = self.low + fraction * self.span;
        if self.log { v.exp() } else { v }
    }
}

#[derive(Default)]
pub struct Picker {
    pub names: Vec<String>,
    pub heading: Option<String>,
    pub format: Option<Format>,
    pub records: Vec<Record>,
    /// Each row's cells joined by tabs, in lower case: what a word is looked for in.
    lower: Vec<String>,
    pub done: bool,
    pub capped: bool,
    pub problems: Vec<String>,
    kinds: Vec<Option<Kind>>,
    widths: Vec<usize>,
    placeholder: String,

    pub query_text: String,
    query: Query,
    pub order: Option<Order>,
    /// The rows the query matches, by place in the input, in the order shown.
    pub shown: Vec<u32>,
    /// Where each row is in `shown`, or `u32::MAX`.
    place: Vec<u32>,
    marked: Vec<bool>,
    pub marked_count: usize,
    marked_shown: usize,
    /// `--where` with `--confirm`: the rule rows are marked by as they come.
    rule_text: Option<String>,
    rule: Option<Query>,
    /// Moves when the rows shown are other rows or in another order.
    pub layout: u64,
    /// Moves when a mark changes.
    pub marks: u64,
    /// Moves when anything the view is told changes.
    pub version: u64,
    sort_keys: HashMap<usize, Vec<SortKey>>,
    /// Rows came while the rows are ordered: they are taken into their places at most a few times a
    /// second, not one by one.
    pub resort_due: Option<Instant>,
    scales: HashMap<usize, Scale>,
}

/// A cell cut to `most` characters, on a character's boundary.
pub fn cut(text: &str, most: usize) -> &str {
    match text.char_indices().nth(most) {
        Some((at, _)) => &text[..at],
        None => text,
    }
}

impl Picker {
    pub fn new(query_text: &str, rule: Option<&str>) -> Self {
        Self {
            query_text: query_text.to_owned(),
            query: query::parse(query_text, &[]),
            rule_text: rule.map(str::to_owned),
            ..Self::default()
        }
    }

    pub fn source(&self) -> Source<'_> {
        Source {
            format: self.format,
            names: &self.names,
            heading: self.heading.as_deref(),
        }
    }

    fn bump(&mut self) {
        self.version += 1;
    }

    // ---- the input ----------------------------------------------------------------------------------

    pub fn columns(&mut self, names: Vec<String>, heading: Option<String>) {
        self.names = names;
        if heading.is_some() {
            self.heading = heading;
        }
        self.query = query::parse(&self.query_text, &self.names);
        if let Some(rule) = &self.rule_text {
            self.rule = Some(query::parse(rule, &self.names));
        }
        if let Some(order) = self.order
            && order.column >= self.names.len()
        {
            self.order = None;
        }
        self.sort_keys.clear();
        self.scales.clear();
        self.read_columns();
        self.refilter();
        self.bump();
    }

    pub fn record(&mut self, record: Record) {
        if self.capped {
            return;
        }
        if self.records.len() >= MAX_ROWS {
            self.capped = true;
            self.bump();
            return;
        }
        let id = self.records.len();
        let lower = query::lower_of(&record.cells);
        let rule_marks = self.rule.as_ref().is_some_and(|rule| query::matches(rule, &record.cells, &lower));
        let matches = self.query.terms.is_empty() || query::matches(&self.query, &record.cells, &lower);
        self.records.push(record);
        self.lower.push(lower);
        self.marked.push(false);
        self.place.push(u32::MAX);
        if rule_marks {
            self.marked[id] = true;
            self.marked_count += 1;
            self.marks += 1;
        }
        if id < KIND_ROWS {
            self.read_columns();
        }
        if matches {
            if self.order.is_some() {
                self.resort_due.get_or_insert_with(Instant::now);
            } else {
                self.place[id] = self.shown.len() as u32;
                self.shown.push(id as u32);
                if self.marked[id] {
                    self.marked_shown += 1;
                }
            }
        }
        self.bump();
    }

    pub fn problem(&mut self, text: String) {
        self.problems.push(text);
        self.bump();
    }

    pub fn finish(&mut self) {
        self.done = true;
        self.bump();
    }

    /// The kinds and widths of the columns, and the query's example, from the first rows.
    fn read_columns(&mut self) {
        let rows = &self.records[..self.records.len().min(KIND_ROWS)];
        self.kinds = (0..self.names.len())
            .map(|column| values::column_kind(rows.iter().map(|r| r.cells.get(column).map_or("", String::as_str))))
            .collect();
        let widths_of = &self.records[..self.records.len().min(WIDTH_ROWS)];
        self.widths = self
            .names
            .iter()
            .enumerate()
            .map(|(column, name)| {
                let longest = widths_of
                    .iter()
                    .map(|r| r.cells.get(column).map_or(0, |c| c.chars().count()))
                    .fold(name.chars().count() + 2, usize::max);
                longest.clamp(4, 60)
            })
            .collect();
        self.placeholder = self.placeholder_of();
    }

    /// What to type, with the input's own columns and values: `STATUS=Running`, `AGE<1h`, from the
    /// column of words with the fewest values and the first column of quantities.
    fn placeholder_of(&self) -> String {
        if self.names.len() <= 1 {
            return "Type to filter: words, !word to leave out — F1 for more".to_owned();
        }
        let simple_name = |name: &str| {
            !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '%' || c == '-')
        };
        let simple_value = |value: &str| {
            let mut chars = value.chars();
            chars.next().is_some_and(char::is_alphabetic)
                && chars.all(|c| c.is_alphanumeric() || c == '_' || c == '-')
        };
        let sample = &self.records[..self.records.len().min(300)];
        let mut examples = Vec::new();
        let mut fewest: Option<(&str, String, usize)> = None;
        for (column, name) in self.names.iter().enumerate() {
            if self.kinds.get(column).copied().flatten().is_some() || !simple_name(name) {
                continue;
            }
            // Counted in the order values first come, so that ties go to the first, as a Map's do.
            let mut counts: Vec<(&str, usize)> = Vec::new();
            for row in sample {
                let value = row.cells.get(column).map_or("", String::as_str);
                if value.is_empty() {
                    continue;
                }
                match counts.iter_mut().find(|(v, _)| *v == value) {
                    Some((_, n)) => *n += 1,
                    None => counts.push((value, 1)),
                }
            }
            let mut best: Option<(&str, usize)> = None;
            for &(value, n) in &counts {
                if best.is_none_or(|(_, m)| n > m) {
                    best = Some((value, n));
                }
            }
            let Some((value, _)) = best else { continue };
            if counts.len() < 2 || !simple_value(value) {
                continue;
            }
            if fewest.as_ref().is_none_or(|(_, _, distinct)| counts.len() < *distinct) {
                fewest = Some((name, value.to_owned(), counts.len()));
            }
        }
        if let Some((name, value, _)) = fewest {
            examples.push(format!("{name}={value}"));
        }
        let quantity_column = self
            .names
            .iter()
            .enumerate()
            .find(|(column, name)| self.kinds.get(*column).copied().flatten().is_some() && simple_name(name));
        if let Some((column, name)) = quantity_column {
            let bound = match self.kinds.get(column).copied().flatten() {
                Some(Kind::Duration) => "<1h",
                Some(Kind::Size) => ">1G",
                Some(Kind::Date) => ">2026-01-01",
                _ => ">10",
            };
            examples.push(format!("{name}{bound}"));
        }
        let mut text = "Type to filter: words, !word".to_owned();
        for example in examples {
            text.push_str(", ");
            text.push_str(&example);
        }
        text.push_str(" — F1 for more");
        text
    }

    // ---- filtering and order ---------------------------------------------------------------------------

    fn keys_of(&mut self, column: usize) -> &Vec<SortKey> {
        let keys = self.sort_keys.entry(column).or_default();
        for record in &self.records[keys.len()..] {
            keys.push(query::sort_key(record.cells.get(column).map_or("", String::as_str)));
        }
        keys
    }

    /// The ids in the order shown; ties keep the input's order.
    fn sort_ids(&mut self, ids: &mut [u32]) {
        let Some(order) = self.order else { return };
        if order.column >= self.names.len() {
            return;
        }
        let keys = self.keys_of(order.column);
        ids.sort_by(|&a, &b| {
            query::compare_ordered(&keys[a as usize], &keys[b as usize], order.descending).then(a.cmp(&b))
        });
    }

    /// The rows the query matches, in the order shown; the windows the view holds are of other rows now.
    pub fn refilter(&mut self) {
        let mut ids: Vec<u32> = if self.query.terms.is_empty() {
            (0..self.records.len() as u32).collect()
        } else {
            (0..self.records.len())
                .filter(|&at| query::matches(&self.query, &self.records[at].cells, &self.lower[at]))
                .map(|at| at as u32)
                .collect()
        };
        self.sort_ids(&mut ids);
        self.place.fill(u32::MAX);
        self.marked_shown = 0;
        for (index, &id) in ids.iter().enumerate() {
            self.place[id as usize] = index as u32;
            if self.marked[id as usize] {
                self.marked_shown += 1;
            }
        }
        self.shown = ids;
        self.resort_due = None;
        self.layout += 1;
        self.bump();
    }

    pub fn set_query(&mut self, text: &str) {
        self.query_text = text.to_owned();
        self.query = query::parse(text, &self.names);
        self.refilter();
    }

    pub fn set_order(&mut self, order: Option<Order>) {
        self.order = order.filter(|o| o.column < self.names.len());
        self.refilter();
    }

    /// The query with a column's term replaced by `term` (or taken out), which is how a click filters.
    pub fn set_term(&mut self, column: usize, term: Option<&str>) {
        let text = query::with_term(&self.query_text, &self.names, column, term);
        self.set_query(&text);
    }

    /// The term that keeps rows whose column is (or is not) this value.
    pub fn term_for(&self, column: usize, value: &str, negate: bool) -> String {
        let name = self.names.get(column).map_or("", String::as_str);
        format!(
            "{}{}{}",
            query::quote_name(name),
            if negate { "!=" } else { "=" },
            query::quote_value(value)
        )
    }

    /// The term of a drag across a column's chart, from one fraction of it to another.
    pub fn range_term(&self, column: usize, low: f64, high: f64) -> Option<String> {
        let scale = self.scales.get(&column)?;
        let name = query::quote_name(self.names.get(column)?);
        Some(format!(
            "{name}={}..{}",
            values::write_quantity(scale.kind, scale.value_at(low)),
            values::write_quantity(scale.kind, scale.value_at(high))
        ))
    }

    // ---- marks ----------------------------------------------------------------------------------------------

    pub fn is_marked(&self, id: usize) -> bool {
        self.marked.get(id).copied().unwrap_or(false)
    }

    pub fn set_marked(&mut self, ids: impl IntoIterator<Item = usize>, on: bool) {
        for id in ids {
            let Some(mark) = self.marked.get_mut(id) else { continue };
            if *mark == on {
                continue;
            }
            *mark = on;
            if on {
                self.marked_count += 1;
            } else {
                self.marked_count -= 1;
            }
            if self.place[id] != u32::MAX {
                if on {
                    self.marked_shown += 1;
                } else {
                    self.marked_shown -= 1;
                }
            }
        }
        self.marks += 1;
        self.bump();
    }

    /// Every row from one to the other, in the order shown, takes the mark.
    pub fn mark_range(&mut self, from: usize, to: usize, on: bool) {
        let at = |id: usize| self.place.get(id).copied().filter(|&p| p != u32::MAX);
        let (Some(a), Some(b)) = (at(from).or(at(to)), at(to)) else { return };
        let (low, high) = (a.min(b) as usize, a.max(b) as usize);
        let ids: Vec<usize> = self.shown[low..=high].iter().map(|&id| id as usize).collect();
        self.set_marked(ids, on);
    }

    pub fn mark_shown(&mut self, on: bool) {
        let ids: Vec<usize> = self.shown.iter().map(|&id| id as usize).collect();
        self.set_marked(ids, on);
    }

    pub fn unmark_all(&mut self) {
        self.marked.fill(false);
        self.marked_count = 0;
        self.marked_shown = 0;
        self.marks += 1;
        self.bump();
    }

    pub fn invert(&mut self) {
        let (on, off): (Vec<usize>, Vec<usize>) =
            self.shown.iter().map(|&id| id as usize).partition(|&id| !self.marked[id]);
        self.set_marked(on, true);
        self.set_marked(off, false);
    }

    /// The rows whose column is this value: of every row, or of the rows the column panel counts.
    pub fn rows_with(&self, column: usize, value: &str, facet: bool) -> Vec<usize> {
        let ids = if facet { self.facet_rows(column) } else { (0..self.records.len()).collect() };
        ids.into_iter()
            .filter(|&id| self.records[id].cells.get(column).map_or("", String::as_str) == value)
            .collect()
    }

    // ---- what goes out ----------------------------------------------------------------------------------

    /// The marked rows, in the order they go out: the order shown, ties in the input's.
    pub fn marked_ids(&mut self) -> Vec<u32> {
        let mut ids: Vec<u32> =
            (0..self.marked.len()).filter(|&id| self.marked[id]).map(|id| id as u32).collect();
        self.sort_ids(&mut ids);
        ids
    }

    /// The rows the rule of `--confirm` matches, every one.
    fn rule_ids(&self) -> Vec<u32> {
        let Some(rule) = &self.rule else { return Vec::new() };
        (0..self.records.len())
            .filter(|&at| query::matches(rule, &self.records[at].cells, &self.lower[at]))
            .map(|at| at as u32)
            .collect()
    }

    pub fn rule_text(&self) -> Option<&str> {
        self.rule_text.as_deref()
    }

    /// Whether the marked rows are exactly these.
    fn marked_are(&self, ids: &[u32]) -> bool {
        self.marked_count == ids.len() && ids.iter().all(|&id| self.marked[id as usize])
    }

    /// The queries that could be the `--where` of the command that does it again: the query typed,
    /// and the rule the rows were marked by when it is another; whether the marked rows are exactly
    /// the rows of one, and which is the one that says what is meant.
    pub fn again_candidates(&self) -> Vec<(String, Vec<u32>, bool)> {
        let mut out = vec![(self.query_text.clone(), self.shown.clone(), false)];
        if let Some(rule) = &self.rule_text
            && rule.trim() != self.query_text.trim()
        {
            out.push((rule.clone(), self.rule_ids(), false));
        }
        for candidate in &mut out {
            candidate.2 = self.marked_are(&candidate.1);
        }
        out
    }

    // ---- what the view is told --------------------------------------------------------------------------

    fn kind_name(kind: Option<Kind>) -> &'static str {
        match kind {
            None => "text",
            Some(kind) => kind.name(),
        }
    }

    pub fn terms_json(&self) -> Value {
        Value::Array(
            self.query
                .terms
                .iter()
                .map(|term| match term {
                    Term::Text { text, negate, from, to } => {
                        json!({ "kind": "text", "text": text, "negate": negate, "from": from, "to": to })
                    }
                    Term::Field { column, op, values, range, from, to, .. } => {
                        let mut v = json!({
                            "kind": "field",
                            "name": self.names.get(*column).cloned().unwrap_or_default(),
                            "op": op.as_str(),
                            "values": values,
                            "from": from,
                            "to": to,
                        });
                        if let Some((low, high)) = range {
                            v["range"] = json!([low, high]);
                        }
                        v
                    }
                })
                .collect(),
        )
    }

    /// What the view is told of the rows: how many there are, are shown and are marked, the columns,
    /// and the numbers that say whether its windows are still of the rows shown.
    pub fn summary(&self) -> Value {
        json!({
            "layout": self.layout,
            "marks": self.marks,
            "total": self.records.len(),
            "shown": self.shown.len(),
            "marked": self.marked_count,
            "marked_shown": self.marked_shown,
            "hidden_marks": self.marked_count - self.marked_shown,
            "done": self.done,
            "capped": self.capped,
            "format": self.format.map(Format::name),
            "columns": self.names,
            "kinds": self.kinds.iter().map(|k| Self::kind_name(*k)).collect::<Vec<_>>(),
            "widths": self.widths,
            "placeholder": self.placeholder,
            "problem": self.problems.last(),
            "terms": self.terms_json(),
            "unknown": query::unknown_names(&self.query_text, &self.names),
        })
    }

    /// The rows `from` to `from + count` of the rows shown, and where the row `cursor` is now.
    pub fn window(&self, from: usize, count: usize, cursor: Option<usize>) -> Value {
        let end = (from + count.min(1000)).min(self.shown.len());
        let rows: Vec<Value> = self.shown[from.min(end)..end]
            .iter()
            .map(|&id| {
                let record = &self.records[id as usize];
                json!({
                    "id": id,
                    "cells": record.cells.iter().map(|c| cut(c, MAX_CELL)).collect::<Vec<_>>(),
                    "marked": self.marked[id as usize],
                })
            })
            .collect();
        let mut out = json!({ "layout": self.layout, "marks": self.marks, "from": from.min(end), "rows": rows });
        if let Some(cursor) = cursor {
            let place = self.place.get(cursor).copied().filter(|&p| p != u32::MAX);
            out["cursor_index"] = json!(place.map_or(-1, i64::from));
        }
        out
    }

    // ---- a column -----------------------------------------------------------------------------------------

    /// The rows the query keeps when its own terms on this column are left out: what the column's
    /// values are counted on.
    pub fn facet_rows(&self, column: usize) -> Vec<usize> {
        let rest = self.query.without_column(column);
        (0..self.records.len())
            .filter(|&at| rest.terms.is_empty() || query::matches(&rest, &self.records[at].cells, &self.lower[at]))
            .collect()
    }

    /// A column's values by how often they come, and a chart of its quantities, among the rows the
    /// rest of the query keeps.
    pub fn facet(&mut self, column: usize) -> Value {
        let ids = self.facet_rows(column);
        let kind = self.kinds.get(column).copied().flatten();
        let limit = if kind.is_none() { 40 } else { 12 };
        // Counted in the order values first come, then by count: ties as a Map's sort leaves them.
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for &id in &ids {
            *counts.entry(self.records[id].cells.get(column).map_or("", String::as_str)).or_default() += 1;
        }
        let distinct = counts.len();
        let mut values: Vec<(&str, usize)> = counts.into_iter().collect();
        values.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
        values.truncate(limit);
        // The values an `=` term on this column chooses, in lower case.
        let chosen: Vec<String> = self
            .query
            .terms
            .iter()
            .find_map(|term| match term {
                Term::Field { column: c, op, values, range: None, .. } if *c == column && op.as_str() == "=" => {
                    Some(values.iter().map(|v| v.to_lowercase()).collect())
                }
                _ => None,
            })
            .unwrap_or_default();
        let values_json: Vec<Value> = values
            .iter()
            .map(|(value, count)| {
                json!({
                    "value": cut(value, MAX_CELL),
                    "count": count,
                    "chosen": chosen.contains(&value.to_lowercase()),
                })
            })
            .collect();
        let mut out = json!({
            "column": column,
            "kind": Self::kind_name(kind),
            "values": values_json,
            "distinct": distinct,
            "rows": ids.len(),
        });
        if let Some(kind) = kind {
            out["chart"] = self.chart(column, kind, &ids);
        }
        out
    }

    const BINS: usize = 36;

    fn chart(&mut self, column: usize, kind: Kind, ids: &[usize]) -> Value {
        let mut numbers: Vec<f64> = ids
            .iter()
            .filter_map(|&id| quantity(self.records[id].cells.get(column).map_or("", String::as_str)))
            .filter(|q| q.kind == kind || q.kind == Kind::Number)
            .map(|q| q.value)
            .collect();
        if numbers.is_empty() {
            return Value::Null;
        }
        numbers.sort_by(|a, b| a.partial_cmp(b).unwrap_or(Ordering::Equal));
        let min = numbers[0];
        let max = numbers[numbers.len() - 1];
        // Times, sizes and counts are often spread over orders of magnitude (most requests take
        // milliseconds, a few seconds): then the chart is in logarithms, so that the many small
        // values are not one bar and the few large ones are still seen.
        let log = min > 0.0 && max / min >= 100.0;
        let mut scale = Scale { kind, low: 0.0, span: 1.0, log };
        scale.low = scale.scale(min);
        let span = scale.scale(max) - scale.low;
        scale.span = if span == 0.0 { 1.0 } else { span };
        let mut bins = vec![0usize; Self::BINS];
        for &v in &numbers {
            let at = (((scale.scale(v) - scale.low) / scale.span) * Self::BINS as f64).floor();
            bins[(at.max(0.0) as usize).min(Self::BINS - 1)] += 1;
        }
        self.scales.insert(column, scale);
        // Where the range of a term on this column is across the chart.
        let range = self.query.terms.iter().find_map(|term| match term {
            Term::Field { column: c, range: Some((low, high)), .. } if *c == column => {
                let (low, high) = (quantity(low)?, quantity(high)?);
                Some(json!([scale.place(low.value), scale.place(high.value)]))
            }
            _ => None,
        });
        json!({
            "bins": bins,
            "min": values::write_quantity(kind, min),
            "max": values::write_quantity(kind, max),
            "median": values::write_quantity(kind, numbers[numbers.len() / 2]),
            "log": log,
            "range": range,
        })
    }
}
