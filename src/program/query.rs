//! The query: what a person types above the rows, and what `--where` runs with no person. One
//! language and one reading of it, in the view and in the program, so that the command line the
//! view shows chooses the rows the view showed.
//!
//! ```text
//!   word            the row holds the word, in any column, in any case
//!   !word           it does not
//!   ^word  word$    a cell starts with the word, or ends with it; `^word$` a cell is the word
//!   "two words"     quotes keep spaces in a word or a value (and `"^a$"` is a word of three)
//!   col=v           the column is v (a quantity compares as one: `size=1G`), `col=a|b` either
//!   col!=v          it is not
//!   col~v  col!~v   it holds v, or does not, in any case
//!   col>v  col>=v  col<v  col<=v
//!                   compared as quantities when both are one (`cpu>50`, `age<2h`, `size>1G`),
//!                   otherwise as text
//!   col=a..b        between a and b, both included
//!   a | b           either term holds: a `|` alone joins the terms on its two sides
//! ```
//!
//! Every term must hold. A column is named as its heading is, in any case, or with only its
//! letters and digits (`cpu` for `%CPU`, `containerid` for `CONTAINER ID`). A name that is no
//! column's makes the whole term a word: `user=bob` searches lines for `user=bob`.
//!
//! Places in the query (`from`, `to`) are byte offsets into its UTF-8 text. Text is put in order
//! by its UTF-16 code units, as the first pickpen, written in JavaScript, put it, so that a
//! character beyond U+FFFF sorts where it did (before U+E000 to U+FFFF, not after).
//!
//! `matches` runs over every row at each key a person presses, so a term carries what it
//! compares already read: its words in lower case and its values' quantities.

use std::cmp::Ordering;

use crate::values::{Quantity, comparable, js_space, js_trim, quantity};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Operator {
    Eq,
    Ne,
    Holds,
    NotHolds,
    Gt,
    Ge,
    Lt,
    Le,
}

impl Operator {
    pub fn as_str(self) -> &'static str {
        match self {
            Operator::Eq => "=",
            Operator::Ne => "!=",
            Operator::Holds => "~",
            Operator::NotHolds => "!~",
            Operator::Gt => ">",
            Operator::Ge => ">=",
            Operator::Lt => "<",
            Operator::Le => "<=",
        }
    }
}

/// Longest first, so that `>=` is not read as `>`.
const OPERATORS: [Operator; 8] = [
    Operator::Ge,
    Operator::Le,
    Operator::Ne,
    Operator::NotHolds,
    Operator::Eq,
    Operator::Holds,
    Operator::Gt,
    Operator::Lt,
];

/// What a field term compares, read once at parse: each value in lower case and as a quantity,
/// so that matching a million rows reads none of them again.
#[derive(Clone, Debug, PartialEq)]
pub struct Prepared {
    /// Each of `values`, read.
    read: Vec<Read>,
    /// The ends of `range`, read.
    bounds: Option<(Read, Read)>,
    /// Whether any value is a quantity, so that a cell's own is worth reading.
    quantities: bool,
}

/// A value as the comparisons use it: in lower case, and as a quantity when it is one.
#[derive(Clone, Debug, PartialEq)]
struct Read {
    text: String,
    lower: String,
    q: Option<Quantity>,
}

impl Read {
    fn new(text: &str) -> Read {
        Read {
            text: text.to_string(),
            lower: text.to_lowercase(),
            q: quantity(text),
        }
    }
}

/// Where in a cell a word is looked for: anywhere, at its start (`^word`), at its end (`word$`),
/// or as the whole of it (`^word$`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum At {
    Anywhere,
    Start,
    End,
    Whole,
}

impl At {
    pub fn name(self) -> &'static str {
        match self {
            At::Anywhere => "anywhere",
            At::Start => "start",
            At::End => "end",
            At::Whole => "whole",
        }
    }
}

// A query has a few terms: boxing the larger kind would save nothing worth a pointer.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq)]
pub enum Term {
    /// A word the row must hold, or must not.
    Text {
        /// In lower case.
        text: String,
        negate: bool,
        at: At,
        from: usize,
        to: usize,
    },
    /// Terms joined by `|`: one of them must hold. What a click writes into the query (`with_term`)
    /// and what a column's panel reads of it (`without_column`, its chosen values and range) are
    /// terms of their own, so a term inside one of these is none of theirs.
    Any {
        terms: Vec<Term>,
        from: usize,
        to: usize,
    },
    /// A comparison of one column.
    Field {
        column: usize,
        op: Operator,
        /// For `=` and `!=`: each alternative of `a|b`. Otherwise one value.
        values: Vec<String>,
        /// For `=` written as `a..b`.
        range: Option<(String, String)>,
        from: usize,
        to: usize,
        prepared: Prepared,
    },
}

impl Term {
    /// Where the term begins in the query, in bytes.
    pub fn from(&self) -> usize {
        match self {
            Term::Text { from, .. } | Term::Any { from, .. } | Term::Field { from, .. } => *from,
        }
    }

    /// Where the term ends in the query, in bytes.
    #[cfg(test)]
    pub fn to(&self) -> usize {
        match self {
            Term::Text { to, .. } | Term::Any { to, .. } | Term::Field { to, .. } => *to,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Query {
    pub terms: Vec<Term>,
    /// The query had nothing to test: every row matches.
    pub empty: bool,
}

impl Default for Query {
    /// The query that keeps every row.
    fn default() -> Self {
        Self {
            terms: Vec::new(),
            empty: true,
        }
    }
}

impl Query {
    /// The query without its terms on `column`: what a column's values are counted on, so that the
    /// panel shows the values the person could choose, not only the one they did.
    pub fn without_column(&self, column: usize) -> Self {
        let terms: Vec<Term> = self
            .terms
            .iter()
            .filter(|term| !matches!(term, Term::Field { column: c, .. } if *c == column))
            .cloned()
            .collect();
        let empty = terms.is_empty();
        Self { terms, empty }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Token<'a> {
    pub text: String,
    /// The token as written, quotes and all, for finding the operator outside quotes.
    pub raw: &'a str,
    pub from: usize,
    pub to: usize,
}

/// Splits on spaces outside quotes; quotes are dropped from the text and kept in `raw`.
pub fn tokenize(source: &str) -> Vec<Token<'_>> {
    let mut tokens = Vec::new();
    let mut chars = source.char_indices().peekable();
    loop {
        while chars.next_if(|(_, c)| js_space(*c)).is_some() {}
        let Some(&(from, _)) = chars.peek() else {
            break;
        };
        let mut text = String::new();
        let mut quote: Option<char> = None;
        let mut to = source.len();
        while let Some(&(at, c)) = chars.peek() {
            if let Some(q) = quote {
                if c == q {
                    quote = None;
                } else {
                    text.push(c);
                }
            } else if c == '"' || c == '\'' {
                quote = Some(c);
            } else if js_space(c) {
                to = at;
                break;
            } else {
                text.push(c);
            }
            chars.next();
        }
        tokens.push(Token {
            text,
            raw: &source[from..to],
            from,
            to,
        });
    }
    tokens
}

/// Letters and digits only, in lower case: how a heading may be named.
pub fn simple_name(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .filter(|c| letter_or_digit(*c))
        .collect()
}

/// Whether a character is a letter or a number, as Unicode's general categories L and N have it
/// (JavaScript's `[\p{L}\p{N}]`): Rust's `is_alphabetic` also counts the marks and symbols that
/// Unicode calls Other_Alphabetic, which are left out here.
fn letter_or_digit(c: char) -> bool {
    if c.is_ascii() {
        return c.is_ascii_alphanumeric();
    }
    if !(c.is_alphabetic() || c.is_numeric()) {
        return false;
    }
    let c = c as u32;
    OTHER_ALPHABETIC
        .binary_search_by(|&(low, high)| {
            if high < c {
                Ordering::Less
            } else if low > c {
                Ordering::Greater
            } else {
                Ordering::Equal
            }
        })
        .is_err()
}

/// The column a name names.
pub fn column_named(columns: &[String], name: &str) -> Option<usize> {
    let lower = name.to_lowercase();
    if let Some(exact) = columns.iter().position(|c| c.to_lowercase() == lower) {
        return Some(exact);
    }
    let simple = simple_name(name);
    if simple.is_empty() {
        return None;
    }
    columns.iter().position(|c| simple_name(c) == simple)
}

/// Where the operator is in a raw token, outside quotes: the first, longest first.
fn find_operator(raw: &str) -> Option<(usize, Operator)> {
    let mut quote: Option<char> = None;
    for (at, c) in raw.char_indices() {
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            continue;
        }
        if c == '"' || c == '\'' {
            quote = Some(c);
            continue;
        }
        let rest = &raw[at..];
        if let Some(op) = OPERATORS.iter().find(|op| rest.starts_with(op.as_str())) {
            return Some((at, *op));
        }
    }
    None
}

fn unquote(raw: &str) -> String {
    let texts: Vec<String> = tokenize(raw).into_iter().map(|t| t.text).collect();
    texts.join(" ")
}

/// A line end, which `.` in a JavaScript pattern does not match.
fn line_end(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// `a..b` as `/^(.*[^.])\.\.([^.].*)$/` reads it: at the last `..` with something not a dot on
/// either side.
fn range_of(value: &str) -> Option<(String, String)> {
    // Tried at each dot, since `...` holds two that overlap; the last first, as `.*` is greedy.
    let mut candidates: Vec<usize> = value
        .char_indices()
        .filter(|(at, _)| value[*at..].starts_with(".."))
        .map(|(at, _)| at)
        .collect();
    candidates.reverse();
    for at in candidates {
        let left = &value[..at];
        let right = &value[at + 2..];
        let Some(last) = left.chars().next_back() else {
            continue;
        };
        let Some(first) = right.chars().next() else {
            continue;
        };
        if last == '.' || first == '.' {
            continue;
        }
        let before = &left[..left.len() - last.len_utf8()];
        let after = &right[first.len_utf8()..];
        if before.chars().any(line_end) || after.chars().any(line_end) {
            continue;
        }
        return Some((left.to_string(), right.to_string()));
    }
    None
}

/// Whether the last character of a raw token is outside quotes, as `$` must be to anchor a word.
fn last_unquoted(raw: &str) -> bool {
    let mut quote: Option<char> = None;
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        if chars.peek().is_none() {
            return quote.is_none();
        }
        match quote {
            Some(q) if c == q => quote = None,
            None if c == '"' || c == '\'' => quote = Some(c),
            _ => {}
        }
    }
    false
}

/// One token as a term: a comparison of a column, a word, or nothing (a word with no text).
fn term_of(token: &Token<'_>, columns: &[String]) -> Option<Term> {
    if let Some((at, op)) = find_operator(token.raw).filter(|(at, _)| *at > 0) {
        let name = unquote(&token.raw[..at]);
        if let Some(column) = column_named(columns, &name) {
            let value = unquote(&token.raw[at + op.as_str().len()..]);
            let range = if op == Operator::Eq {
                range_of(&value)
            } else {
                None
            };
            let values: Vec<String> = if op == Operator::Eq || op == Operator::Ne {
                value.split('|').map(str::to_string).collect()
            } else {
                vec![value]
            };
            let read: Vec<Read> = values.iter().map(|v| Read::new(v)).collect();
            let bounds = range
                .as_ref()
                .map(|(low, high)| (Read::new(low), Read::new(high)));
            let quantities = read.iter().any(|r| r.q.is_some())
                || bounds
                    .as_ref()
                    .is_some_and(|(l, h)| l.q.is_some() || h.q.is_some());
            return Some(Term::Field {
                column,
                op,
                values,
                range,
                from: token.from,
                to: token.to,
                prepared: Prepared {
                    read,
                    bounds,
                    quantities,
                },
            });
        }
    }
    // `!`, then `^`, then `$` at the end, each outside quotes and with something besides itself.
    let mut raw = token.raw;
    let negate = raw.starts_with('!') && raw.len() > 1;
    if negate {
        raw = &raw[1..];
    }
    let start = raw.starts_with('^') && raw.len() > 1;
    if start {
        raw = &raw[1..];
    }
    let end = raw.ends_with('$') && raw.len() > 1 && last_unquoted(raw);
    if end {
        raw = &raw[..raw.len() - 1];
    }
    let text = unquote(raw);
    if text.is_empty() {
        return None;
    }
    Some(Term::Text {
        text: text.to_lowercase(),
        negate,
        at: match (start, end) {
            (false, false) => At::Anywhere,
            (true, false) => At::Start,
            (false, true) => At::End,
            (true, true) => At::Whole,
        },
        from: token.from,
        to: token.to,
    })
}

pub fn parse(source: &str, columns: &[String]) -> Query {
    let mut terms: Vec<Term> = Vec::new();
    // A `|` alone came after the last term: the next one is its other side.
    let mut join = false;
    for token in tokenize(source) {
        if token.raw == "|" {
            join = !terms.is_empty();
            continue;
        }
        let Some(term) = term_of(&token, columns) else {
            continue;
        };
        let last = if join { terms.pop() } else { None };
        join = false;
        terms.push(match last {
            Some(Term::Any {
                terms: mut any,
                from,
                ..
            }) => {
                any.push(term);
                Term::Any {
                    terms: any,
                    from,
                    to: token.to,
                }
            }
            Some(last) => Term::Any {
                from: last.from(),
                terms: vec![last, term],
                to: token.to,
            },
            None => term,
        });
    }
    let empty = terms.is_empty();
    Query { terms, empty }
}

/// The names a query compares that are no column's, each once: such a term is looked for as a
/// word, which is seldom what was meant, so the view marks it and `--where` says so.
pub fn unknown_names(source: &str, columns: &[String]) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for token in tokenize(source) {
        let Some((at, _)) = find_operator(token.raw) else {
            continue;
        };
        if at == 0 {
            continue;
        }
        let name = unquote(&token.raw[..at]);
        if column_named(columns, &name).is_none() && !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

/// The text a word is looked for in: the cells joined by tabs, in lower case.
pub fn lower_of(cells: &[String]) -> String {
    cells.join("\t").to_lowercase()
}

/// What a row is to a query: its cells, and the text a word is looked for in.
#[derive(Clone, Debug, PartialEq)]
#[cfg(test)]
pub struct Row {
    pub cells: Vec<String>,
    /// The cells joined by tabs, in lower case.
    pub lower: String,
}

#[cfg(test)]
impl Row {
    pub fn new(cells: Vec<String>) -> Row {
        let lower = lower_of(&cells);
        Row { cells, lower }
    }
}

/// Text in order, with runs of digits by their number, without regard to case: `file9` before
/// `file10`. A plain loop, not a collation, so that the view and the program, on two machines,
/// put rows in one order.
pub fn compare_text(a: &str, b: &str) -> Ordering {
    if a.is_ascii() && b.is_ascii() {
        let (x, y) = (a.as_bytes(), b.as_bytes());
        let order = compare_lowered(
            x.len(),
            |i| u32::from(x[i].to_ascii_lowercase()),
            y.len(),
            |j| u32::from(y[j].to_ascii_lowercase()),
        );
        return order.then_with(|| a.cmp(b));
    }
    let x: Vec<u16> = a.to_lowercase().encode_utf16().collect();
    let y: Vec<u16> = b.to_lowercase().encode_utf16().collect();
    let order = compare_lowered(x.len(), |i| u32::from(x[i]), y.len(), |j| u32::from(y[j]));
    order.then_with(|| a.encode_utf16().cmp(b.encode_utf16()))
}

/// `compare_text` on two texts already in lower case, given as their lengths and code units.
fn compare_lowered(
    xl: usize,
    x: impl Fn(usize) -> u32,
    yl: usize,
    y: impl Fn(usize) -> u32,
) -> Ordering {
    let digit = |c: u32| (48..=57).contains(&c);
    let (mut i, mut j) = (0, 0);
    while i < xl && j < yl {
        let (cx, cy) = (x(i), y(j));
        if digit(cx) && digit(cy) {
            let mut ei = i;
            let mut ej = j;
            while ei < xl && digit(x(ei)) {
                ei += 1;
            }
            while ej < yl && digit(y(ej)) {
                ej += 1;
            }
            // Leading zeros go, but not the last digit.
            let mut si = i;
            while si + 1 < ei && x(si) == 48 {
                si += 1;
            }
            let mut sj = j;
            while sj + 1 < ej && y(sj) == 48 {
                sj += 1;
            }
            let (nx, ny) = (ei - si, ej - sj);
            if nx != ny {
                return nx.cmp(&ny);
            }
            for k in 0..nx {
                let (dx, dy) = (x(si + k), y(sj + k));
                if dx != dy {
                    return dx.cmp(&dy);
                }
            }
            i = ei;
            j = ej;
            continue;
        }
        if cx != cy {
            return cx.cmp(&cy);
        }
        i += 1;
        j += 1;
    }
    (xl - i).cmp(&(yl - j))
}

/// A cell as the sort reads it, read once so that a long sort parses each cell once.
#[derive(Clone, Debug, PartialEq)]
pub struct SortKey {
    pub text: String,
    pub empty: bool,
    pub q: Option<Quantity>,
}

pub fn sort_key(cell: &str) -> SortKey {
    let empty = js_trim(cell).is_empty();
    SortKey {
        text: cell.to_string(),
        empty,
        q: if empty { None } else { quantity(cell) },
    }
}

/// Empty cells after the others, whichever the order.
fn empty_last(a: &SortKey, b: &SortKey) -> Ordering {
    match (a.empty, b.empty) {
        (true, true) | (false, false) => Ordering::Equal,
        (true, false) => Ordering::Greater,
        (false, true) => Ordering::Less,
    }
}

/// The order of a difference of quantities; none for no difference, or none to tell (NaN).
fn order_of(d: f64) -> Option<Ordering> {
    if d > 0.0 {
        Some(Ordering::Greater)
    } else if d < 0.0 {
        Some(Ordering::Less)
    } else {
        None
    }
}

/// Two cells in order: quantities that compare as quantities, before words, which compare as
/// text; empty cells last. The order is the same in the view and with `--sort`.
pub fn compare_keys(a: &SortKey, b: &SortKey) -> Ordering {
    if a.empty || b.empty {
        return empty_last(a, b);
    }
    match (a.q, b.q) {
        (Some(qa), Some(qb)) if comparable(qa, qb) => {
            order_of(qa.value - qb.value).unwrap_or_else(|| compare_text(&a.text, &b.text))
        }
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (Some(qa), Some(qb)) => qa
            .kind
            .name()
            .cmp(qb.kind.name())
            .then_with(|| order_of(qa.value - qb.value).unwrap_or(Ordering::Equal)),
        (None, None) => compare_text(&a.text, &b.text),
    }
}

/// The order `--sort` and the view's headings put rows in: empty cells last either way.
pub fn compare_ordered(a: &SortKey, b: &SortKey, descending: bool) -> Ordering {
    if a.empty || b.empty {
        return empty_last(a, b);
    }
    let d = compare_keys(a, b);
    if descending { d.reverse() } else { d }
}

/// Where a cell stands to a value, or none when the two do not compare.
fn order(cell: &str, value: &Read, cell_q: Option<Quantity>) -> Option<Ordering> {
    if let Some(value_q) = value.q {
        let cell_q = cell_q.filter(|q| comparable(*q, value_q))?;
        // A difference that is NaN (∞ - ∞) is neither above, below nor the same.
        return (cell_q.value - value_q.value).partial_cmp(&0.0);
    }
    let cell = js_trim(cell);
    if cell.is_empty() {
        return None;
    }
    Some(compare_text(cell, &value.text))
}

/// Whether two texts are one in lower case, the second already lower.
fn same_lower(text: &str, lower: &str) -> bool {
    if text.is_ascii() {
        text.len() == lower.len()
            && text
                .bytes()
                .zip(lower.bytes())
                .all(|(a, b)| a.to_ascii_lowercase() == b)
    } else {
        text.to_lowercase() == lower
    }
}

/// Whether a text holds another in lower case, the second already lower.
fn holds_lower(text: &str, lower: &str) -> bool {
    if text.is_ascii() {
        if !lower.is_ascii() {
            return false;
        }
        let (hay, needle) = (text.as_bytes(), lower.as_bytes());
        if needle.is_empty() {
            return true;
        }
        hay.windows(needle.len()).any(|w| {
            w.iter()
                .zip(needle)
                .all(|(a, b)| a.to_ascii_lowercase() == *b)
        })
    } else {
        text.to_lowercase().contains(lower)
    }
}

fn equal(cell: &str, value: &Read, cell_q: Option<Quantity>) -> bool {
    if let (Some(value_q), Some(cell_q)) = (value.q, cell_q)
        && comparable(cell_q, value_q)
    {
        return cell_q.value == value_q.value;
    }
    same_lower(js_trim(cell), &value.lower)
}

/// Whether a word is where `at` says in a cell of the row, `lower` being its cells joined by tabs.
fn has_word(lower: &str, text: &str, at: At) -> bool {
    match at {
        At::Anywhere => lower.contains(text),
        At::Start => lower.split('\t').any(|cell| cell.starts_with(text)),
        At::End => lower.split('\t').any(|cell| cell.ends_with(text)),
        At::Whole => lower.split('\t').any(|cell| cell == text),
    }
}

fn holds(term: &Term, cells: &[String], lower: &str) -> bool {
    let (column, op, term) = match term {
        Term::Text {
            text, negate, at, ..
        } => return has_word(lower, text, *at) != *negate,
        Term::Any { terms, .. } => return terms.iter().any(|t| holds(t, cells, lower)),
        Term::Field {
            column,
            op,
            prepared,
            ..
        } => (*column, *op, prepared),
    };
    let cell = cells.get(column).map_or("", String::as_str);
    let cell_q = if term.quantities {
        quantity(cell)
    } else {
        None
    };
    let first = term.read.first();
    match op {
        Operator::Eq => {
            if let Some((low, high)) = &term.bounds {
                let low = order(cell, low, cell_q);
                let high = order(cell, high, cell_q);
                return matches!(low, Some(Ordering::Greater | Ordering::Equal))
                    && matches!(high, Some(Ordering::Less | Ordering::Equal));
            }
            term.read.iter().any(|v| equal(cell, v, cell_q))
        }
        Operator::Ne => !term.read.iter().any(|v| equal(cell, v, cell_q)),
        Operator::Holds => first.is_some_and(|v| holds_lower(cell, &v.lower)),
        Operator::NotHolds => !first.is_some_and(|v| holds_lower(cell, &v.lower)),
        op => {
            let Some(d) = first.and_then(|v| order(cell, v, cell_q)) else {
                return false;
            };
            match op {
                Operator::Gt => d == Ordering::Greater,
                Operator::Ge => d != Ordering::Less,
                Operator::Lt => d == Ordering::Less,
                _ => d != Ordering::Greater,
            }
        }
    }
}

/// Whether a row holds every term: `cells` are its cells, `lower` what `lower_of` makes of them.
pub fn matches(query: &Query, cells: &[String], lower: &str) -> bool {
    query.terms.iter().all(|term| holds(term, cells, lower))
}

/// `matches` for a `Row`.
#[cfg(test)]
pub fn row_matches(query: &Query, row: &Row) -> bool {
    matches(query, &row.cells, &row.lower)
}

/// A value as the query needs it written: quoted when it has a space, a quote or an operator.
pub fn quote_value(value: &str) -> String {
    let special =
        |c: char| js_space(c) || matches!(c, '"' | '\'' | '=' | '!' | '~' | '<' | '>' | '|');
    if !value.is_empty() && !value.chars().any(special) {
        return value.to_string();
    }
    if value.contains('"') {
        format!("'{value}'")
    } else {
        format!("\"{value}\"")
    }
}

/// A column's name as the query needs it written.
pub fn quote_name(name: &str) -> String {
    quote_value(name)
}

/// The query with the terms on one column replaced by `term` (or removed, for `None`), which is
/// how the view's clicks write into what the person types.
pub fn with_term(source: &str, columns: &[String], column: usize, term: Option<&str>) -> String {
    let parsed = parse(source, columns);
    let mut out = String::new();
    let mut at = 0;
    let mut placed = false;
    for t in &parsed.terms {
        if let Term::Field {
            column: c,
            from,
            to,
            ..
        } = t
            && *c == column
        {
            out.push_str(source.get(at..*from).unwrap_or(""));
            if let (false, Some(term)) = (placed, term) {
                out.push_str(term);
                placed = true;
            }
            at = *to;
        }
    }
    out.push_str(&source[at..]);
    let mut out = js_trim(&squeeze_spaces(&out)).to_string();
    if let (false, Some(term)) = (placed, term) {
        out = if out.is_empty() {
            term.to_string()
        } else {
            format!("{out} {term}")
        };
    }
    out
}

/// Runs of two spaces or more as one space, as `.replace(/\s{2,}/g, " ")`; a lone one is kept as
/// it is.
fn squeeze_spaces(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut run = String::new();
    let flush = |out: &mut String, run: &mut String| {
        if run.chars().count() >= 2 {
            out.push(' ');
        } else {
            out.push_str(run);
        }
        run.clear();
    };
    for c in text.chars() {
        if js_space(c) {
            run.push(c);
        } else {
            flush(&mut out, &mut run);
            out.push(c);
        }
    }
    flush(&mut out, &mut run);
    out
}

/// The characters Rust's `is_alphabetic` counts that are no letter of Unicode's categories
/// (Other_Alphabetic: vowel signs, combining marks, circled letters), as inclusive ranges.
const OTHER_ALPHABETIC: &[(u32, u32)] = &[
    (0x345, 0x345),
    (0x363, 0x36F),
    (0x5B0, 0x5BD),
    (0x5BF, 0x5BF),
    (0x5C1, 0x5C2),
    (0x5C4, 0x5C5),
    (0x5C7, 0x5C7),
    (0x610, 0x61A),
    (0x64B, 0x657),
    (0x659, 0x65F),
    (0x670, 0x670),
    (0x6D6, 0x6DC),
    (0x6E1, 0x6E4),
    (0x6E7, 0x6E8),
    (0x6ED, 0x6ED),
    (0x711, 0x711),
    (0x730, 0x73F),
    (0x7A6, 0x7B0),
    (0x816, 0x817),
    (0x81B, 0x823),
    (0x825, 0x827),
    (0x829, 0x82C),
    (0x897, 0x897),
    (0x8D4, 0x8DF),
    (0x8E3, 0x8E9),
    (0x8F0, 0x903),
    (0x93A, 0x93B),
    (0x93E, 0x94C),
    (0x94E, 0x94F),
    (0x955, 0x957),
    (0x962, 0x963),
    (0x981, 0x983),
    (0x9BE, 0x9C4),
    (0x9C7, 0x9C8),
    (0x9CB, 0x9CC),
    (0x9D7, 0x9D7),
    (0x9E2, 0x9E3),
    (0xA01, 0xA03),
    (0xA3E, 0xA42),
    (0xA47, 0xA48),
    (0xA4B, 0xA4C),
    (0xA51, 0xA51),
    (0xA70, 0xA71),
    (0xA75, 0xA75),
    (0xA81, 0xA83),
    (0xABE, 0xAC5),
    (0xAC7, 0xAC9),
    (0xACB, 0xACC),
    (0xAE2, 0xAE3),
    (0xAFA, 0xAFC),
    (0xB01, 0xB03),
    (0xB3E, 0xB44),
    (0xB47, 0xB48),
    (0xB4B, 0xB4C),
    (0xB56, 0xB57),
    (0xB62, 0xB63),
    (0xB82, 0xB82),
    (0xBBE, 0xBC2),
    (0xBC6, 0xBC8),
    (0xBCA, 0xBCC),
    (0xBD7, 0xBD7),
    (0xC00, 0xC04),
    (0xC3E, 0xC44),
    (0xC46, 0xC48),
    (0xC4A, 0xC4C),
    (0xC55, 0xC56),
    (0xC62, 0xC63),
    (0xC81, 0xC83),
    (0xCBE, 0xCC4),
    (0xCC6, 0xCC8),
    (0xCCA, 0xCCC),
    (0xCD5, 0xCD6),
    (0xCE2, 0xCE3),
    (0xCF3, 0xCF3),
    (0xD00, 0xD03),
    (0xD3E, 0xD44),
    (0xD46, 0xD48),
    (0xD4A, 0xD4C),
    (0xD57, 0xD57),
    (0xD62, 0xD63),
    (0xD81, 0xD83),
    (0xDCF, 0xDD4),
    (0xDD6, 0xDD6),
    (0xDD8, 0xDDF),
    (0xDF2, 0xDF3),
    (0xE31, 0xE31),
    (0xE34, 0xE3A),
    (0xE4D, 0xE4D),
    (0xEB1, 0xEB1),
    (0xEB4, 0xEB9),
    (0xEBB, 0xEBC),
    (0xECD, 0xECD),
    (0xF71, 0xF83),
    (0xF8D, 0xF97),
    (0xF99, 0xFBC),
    (0x102B, 0x1036),
    (0x1038, 0x1038),
    (0x103B, 0x103E),
    (0x1056, 0x1059),
    (0x105E, 0x1060),
    (0x1062, 0x1064),
    (0x1067, 0x106D),
    (0x1071, 0x1074),
    (0x1082, 0x108D),
    (0x108F, 0x108F),
    (0x109A, 0x109D),
    (0x1712, 0x1713),
    (0x1732, 0x1733),
    (0x1752, 0x1753),
    (0x1772, 0x1773),
    (0x17B6, 0x17C8),
    (0x1885, 0x1886),
    (0x18A9, 0x18A9),
    (0x1920, 0x192B),
    (0x1930, 0x1938),
    (0x1A17, 0x1A1B),
    (0x1A55, 0x1A5E),
    (0x1A61, 0x1A74),
    (0x1ABF, 0x1AC0),
    (0x1ACC, 0x1ACE),
    (0x1B00, 0x1B04),
    (0x1B35, 0x1B43),
    (0x1B80, 0x1B82),
    (0x1BA1, 0x1BA9),
    (0x1BAC, 0x1BAD),
    (0x1BE7, 0x1BF1),
    (0x1C24, 0x1C36),
    (0x1DD3, 0x1DF4),
    (0x24B6, 0x24E9),
    (0x2DE0, 0x2DFF),
    (0xA674, 0xA67B),
    (0xA69E, 0xA69F),
    (0xA802, 0xA802),
    (0xA80B, 0xA80B),
    (0xA823, 0xA827),
    (0xA880, 0xA881),
    (0xA8B4, 0xA8C3),
    (0xA8C5, 0xA8C5),
    (0xA8FF, 0xA8FF),
    (0xA926, 0xA92A),
    (0xA947, 0xA952),
    (0xA980, 0xA983),
    (0xA9B4, 0xA9BF),
    (0xA9E5, 0xA9E5),
    (0xAA29, 0xAA36),
    (0xAA43, 0xAA43),
    (0xAA4C, 0xAA4D),
    (0xAA7B, 0xAA7D),
    (0xAAB0, 0xAAB0),
    (0xAAB2, 0xAAB4),
    (0xAAB7, 0xAAB8),
    (0xAABE, 0xAABE),
    (0xAAEB, 0xAAEF),
    (0xAAF5, 0xAAF5),
    (0xABE3, 0xABEA),
    (0xFB1E, 0xFB1E),
    (0x10376, 0x1037A),
    (0x10A01, 0x10A03),
    (0x10A05, 0x10A06),
    (0x10A0C, 0x10A0F),
    (0x10D24, 0x10D27),
    (0x10D69, 0x10D69),
    (0x10EAB, 0x10EAC),
    (0x10EFC, 0x10EFC),
    (0x11000, 0x11002),
    (0x11038, 0x11045),
    (0x11073, 0x11074),
    (0x11080, 0x11082),
    (0x110B0, 0x110B8),
    (0x110C2, 0x110C2),
    (0x11100, 0x11102),
    (0x11127, 0x11132),
    (0x11145, 0x11146),
    (0x11180, 0x11182),
    (0x111B3, 0x111BF),
    (0x111CE, 0x111CF),
    (0x1122C, 0x11234),
    (0x11237, 0x11237),
    (0x1123E, 0x1123E),
    (0x11241, 0x11241),
    (0x112DF, 0x112E8),
    (0x11300, 0x11303),
    (0x1133E, 0x11344),
    (0x11347, 0x11348),
    (0x1134B, 0x1134C),
    (0x11357, 0x11357),
    (0x11362, 0x11363),
    (0x113B8, 0x113C0),
    (0x113C2, 0x113C2),
    (0x113C5, 0x113C5),
    (0x113C7, 0x113CA),
    (0x113CC, 0x113CD),
    (0x11435, 0x11441),
    (0x11443, 0x11445),
    (0x114B0, 0x114C1),
    (0x115AF, 0x115B5),
    (0x115B8, 0x115BE),
    (0x115DC, 0x115DD),
    (0x11630, 0x1163E),
    (0x11640, 0x11640),
    (0x116AB, 0x116B5),
    (0x1171D, 0x1172A),
    (0x1182C, 0x11838),
    (0x11930, 0x11935),
    (0x11937, 0x11938),
    (0x1193B, 0x1193C),
    (0x11940, 0x11940),
    (0x11942, 0x11942),
    (0x119D1, 0x119D7),
    (0x119DA, 0x119DF),
    (0x119E4, 0x119E4),
    (0x11A01, 0x11A0A),
    (0x11A35, 0x11A39),
    (0x11A3B, 0x11A3E),
    (0x11A51, 0x11A5B),
    (0x11A8A, 0x11A97),
    (0x11C2F, 0x11C36),
    (0x11C38, 0x11C3E),
    (0x11C92, 0x11CA7),
    (0x11CA9, 0x11CB6),
    (0x11D31, 0x11D36),
    (0x11D3A, 0x11D3A),
    (0x11D3C, 0x11D3D),
    (0x11D3F, 0x11D41),
    (0x11D43, 0x11D43),
    (0x11D47, 0x11D47),
    (0x11D8A, 0x11D8E),
    (0x11D90, 0x11D91),
    (0x11D93, 0x11D96),
    (0x11EF3, 0x11EF6),
    (0x11F00, 0x11F01),
    (0x11F03, 0x11F03),
    (0x11F34, 0x11F3A),
    (0x11F3E, 0x11F40),
    (0x1611E, 0x1612E),
    (0x16F4F, 0x16F4F),
    (0x16F51, 0x16F87),
    (0x16F8F, 0x16F92),
    (0x16FF0, 0x16FF1),
    (0x1BC9E, 0x1BC9E),
    (0x1E000, 0x1E006),
    (0x1E008, 0x1E018),
    (0x1E01B, 0x1E021),
    (0x1E023, 0x1E024),
    (0x1E026, 0x1E02A),
    (0x1E08F, 0x1E08F),
    (0x1E947, 0x1E947),
    (0x1F130, 0x1F149),
    (0x1F150, 0x1F169),
    (0x1F170, 0x1F189),
];

#[cfg(test)]
#[path = "query_tests.rs"]
mod tests;
