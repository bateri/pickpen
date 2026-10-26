//! The calls and the topic of the view, over the picker the input fills.
//!
//! The view holds where the person is and asks for the rows in sight; what needs every row (the
//! filter, the order, the marks, a column's counts, what goes out) is done here. Its calls:
//!
//! - `boot`: how the command line set the view up, and the rows so far
//! - the topic `table`: what the view is told of the rows, again whenever it changes
//! - `query`, `order`, `term`: the rows shown, by what the person typed, the order, or a click
//! - `window`: the rows at some places of those shown
//! - `mark`, `mark_range`, `mark_shown`, `unmark_all`, `invert`, `mark_value`: the marks
//! - `column`: a column's values and chart; `output`: what Send would write, and the command line
//!   that does it again; `preview`: what `--preview` prints for a row; `copy_row`
//! - `choose`: the rows to send, after which the view closes and the program writes them.

use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use pencere::{Call, CloseResult, Options, Subscription, ViewControl, ViewError};
use serde_json::{Value, json};

use crate::args::Run;
use crate::command::{Recipe, command_line};
use crate::output::{self, Shape};
use crate::picker::{Order, Picker};
use crate::preview;
use crate::query;

/// How long `boot` waits for the input, so that the view opens on its rows rather than on nothing (a
/// short input whole, the first of a long one).
const FIRST_ROWS: Duration = Duration::from_millis(300);
/// How often the topic looks for a change to tell, and how long a sorted list waits to take new rows
/// into their places.
const TICK: Duration = Duration::from_millis(50);
const RESORT_AFTER: Duration = Duration::from_millis(250);
/// How long the answer to `choose` or `cancel` has to reach the view before the program closes it.
const CLOSE_AFTER: Duration = Duration::from_millis(50);
/// The most rows the output panel draws.
const OUTPUT_ROWS: usize = 200;

/// The picker and the bell that rings when it changes.
pub struct Shared {
    pub picker: Mutex<Picker>,
    pub changed: Condvar,
    /// The rows the person chose and their shape, once they have.
    pub answer: Mutex<Option<(Vec<u32>, Shape)>>,
    /// The person sent nothing.
    pub cancelled: Mutex<bool>,
}

impl Shared {
    pub fn new(picker: Picker) -> Arc<Self> {
        Arc::new(Self {
            picker: Mutex::new(picker),
            changed: Condvar::new(),
            answer: Mutex::new(None),
            cancelled: Mutex::new(false),
        })
    }

    pub fn lock(&self) -> MutexGuard<'_, Picker> {
        self.picker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Something changed: the topic tells the view.
    pub fn ring(&self) {
        self.changed.notify_all();
    }
}

fn bad(message: impl Into<String>) -> ViewError {
    ViewError::with_message("bad-params", message)
}

fn column_of(params: &Value, picker: &Picker) -> Result<usize, ViewError> {
    params["column"]
        .as_u64()
        .map(|c| c as usize)
        .filter(|&c| c < picker.names.len())
        .ok_or_else(|| bad("There is no such column"))
}

fn ids_of(params: &Value, key: &str) -> Vec<usize> {
    params[key].as_array().map_or_else(Vec::new, |ids| {
        ids.iter()
            .filter_map(Value::as_u64)
            .map(|id| id as usize)
            .collect()
    })
}

fn fields_of(params: &Value) -> Option<Vec<String>> {
    params["fields"].as_array().map(|fields| {
        fields
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    })
}

/// The shape of the output: the columns the person picked in the view, or the command line's.
fn shape_of(run: &Run, fields: Option<&[String]>) -> Shape {
    match fields {
        Some(fields) if !fields.is_empty() => Shape::Fields(fields.to_vec()),
        _ => run.shape.clone(),
    }
}

/// The rows Send sends, in the order they go out: the marked ones, or the cursor's row.
fn to_send(picker: &mut Picker, run: &Run, cursor: Option<usize>) -> Vec<u32> {
    if picker.marked_count > 0 {
        return picker.marked_ids();
    }
    match cursor {
        Some(id) if !run.confirm && id < picker.records.len() => vec![id as u32],
        _ => Vec::new(),
    }
}

/// The command line that does again what Send would do, with nobody to ask, and whether it does: it
/// does when the rows marked are exactly the rows a query matches — the query typed, or, with
/// `--confirm`, the rule the rows were marked by.
fn again(picker: &Picker, run: &Run, fields: Option<&[String]>) -> Value {
    let field = fields
        .map(<[String]>::to_vec)
        .or_else(|| run.given.field.clone());
    let line_for = |where_: &str| {
        command_line(&Recipe {
            input: run.given.input.clone(),
            where_: where_.to_owned(),
            sort: picker.order.map(|o| {
                (
                    picker.names.get(o.column).cloned().unwrap_or_default(),
                    o.descending,
                )
            }),
            field: field.clone().filter(|f| !f.is_empty()),
            format: run.given.format.clone(),
            output: run.given.output.clone(),
        })
    };
    let candidates = picker.again_candidates();
    // The query typed says what is meant once there is one; until then, the rule does.
    let main = if picker.query_text.trim().is_empty() && candidates.len() > 1 {
        &candidates[1]
    } else {
        &candidates[0]
    };
    if picker.marked_count == 0 {
        return json!({ "kind": "none", "line": line_for(&main.0), "where": main.0 });
    }
    if let Some(same) = candidates.iter().find(|c| c.2) {
        return json!({ "kind": "same", "line": line_for(&same.0), "rows": same.1.len(), "where": same.0 });
    }
    json!({
        "kind": "different",
        "line": line_for(&main.0),
        "rows": main.1.len(),
        "chosen": picker.marked_count,
        "where": main.0,
    })
}

/// The answer to a change of the rows shown, with the query as it is now.
fn shown_now(picker: &Picker) -> Value {
    let mut sum = picker.summary();
    sum["query"] = json!(picker.query_text);
    sum
}

/// After the answer has gone back to the view: the program closes its view, and goes on to write.
/// The view closes itself too once it has its answer, for a terminal that cannot close it for the
/// program; whichever comes first does, and the other finds nothing to close.
fn close_soon(control: &ViewControl) {
    let control = control.clone();
    std::thread::spawn(move || {
        std::thread::sleep(CLOSE_AFTER);
        // A terminal that cannot (`Unsupported`) has the view close itself; nothing is printed
        // while the view has the terminal.
        let _: CloseResult = control.close();
    });
}

/// The view's calls and its topic, on `options`; `control` closes the view once the person has
/// answered.
pub fn serve(
    options: Options,
    shared: &Arc<Shared>,
    run: &Arc<Run>,
    control: &ViewControl,
    version: &'static str,
) -> Options {
    let s = shared.clone();
    let r = run.clone();
    let options = options.call("boot", move |_params, _call: &Call| {
        // A moment for the rows.
        let deadline = Instant::now() + FIRST_ROWS;
        let mut picker = s.lock();
        while !picker.done && !picker.capped && Instant::now() < deadline {
            let left = deadline.saturating_duration_since(Instant::now());
            picker = s
                .changed
                .wait_timeout(picker, left)
                .map_or_else(|e| e.into_inner().0, |r| r.0);
        }
        let mut boot = json!({
            "version": version,
            "title": r.title,
            "query": r.query,
            "where": r.where_,
            "confirm": r.confirm,
            "preview": r.preview,
            "given": {
                "input": r.given.input,
                "field": r.given.field,
                "format": r.given.format,
                "output": r.given.output,
            },
        });
        if let Some(sort) = &r.sort {
            match query::column_named(&picker.names, &sort.column) {
                Some(column) => {
                    picker.set_order(Some(Order {
                        column,
                        descending: sort.descending,
                    }));
                    boot["order"] = json!({ "column": column, "descending": sort.descending });
                }
                None => {
                    boot["sort_problem"] = json!(format!(
                        "There is no column named {} to sort by",
                        json!(sort.column)
                    ));
                }
            }
        }
        boot["summary"] = picker.summary();
        Ok(boot)
    });

    let s = shared.clone();
    let options = options.topic("table", move |_params, subscription: &Subscription| {
        let feed = subscription.clone();
        let s = s.clone();
        std::thread::spawn(move || {
            let mut told = u64::MAX;
            loop {
                let summary = {
                    let mut picker = s.lock();
                    picker = s
                        .changed
                        .wait_timeout(picker, TICK)
                        .map_or_else(|e| e.into_inner().0, |r| r.0);
                    if picker
                        .resort_due
                        .is_some_and(|due| due.elapsed() >= RESORT_AFTER)
                    {
                        picker.refilter();
                    }
                    if picker.version == told {
                        None
                    } else {
                        told = picker.version;
                        Some(picker.summary())
                    }
                };
                if feed.is_cancelled() {
                    break;
                }
                if let Some(summary) = summary
                    && !feed.push(summary)
                {
                    break;
                }
                // At most a few times a second while rows pour in.
                if feed.sleep(TICK) {
                    break;
                }
            }
        });
        Ok(())
    });

    let s = shared.clone();
    let options = options.call("query", move |params, _call: &Call| {
        let text = params["query"].as_str().unwrap_or_default();
        let mut picker = s.lock();
        if text != picker.query_text || picker.resort_due.is_some() {
            picker.set_query(text);
        }
        Ok(shown_now(&picker))
    });

    let s = shared.clone();
    let options = options.call("order", move |params, _call: &Call| {
        let mut picker = s.lock();
        let order = params["column"].as_u64().map(|column| Order {
            column: column as usize,
            descending: params["descending"].as_bool().unwrap_or(false),
        });
        picker.set_order(order);
        Ok(shown_now(&picker))
    });

    let s = shared.clone();
    let options = options.call("term", move |params, _call: &Call| {
        let mut picker = s.lock();
        let column = column_of(&params, &picker)?;
        let name = query::quote_name(&picker.names[column]);
        let negate = params["negate"].as_bool().unwrap_or(false);
        let term = if params["clear"].as_bool() == Some(true) {
            None
        } else if let Some(id) = params["id"].as_u64() {
            let value = picker
                .records
                .get(id as usize)
                .ok_or_else(|| bad("There is no such row"))?
                .cells
                .get(column)
                .cloned()
                .unwrap_or_default();
            Some(picker.term_for(column, &value, negate))
        } else if let Some(value) = params["value"].as_str() {
            Some(picker.term_for(column, value, negate))
        } else if let Some(values) = params["values"].as_array() {
            let values: Vec<String> = values
                .iter()
                .filter_map(Value::as_str)
                .map(query::quote_value)
                .collect();
            Some(format!("{name}={}", values.join("|")))
        } else if let Some(range) = params["range"].as_array() {
            let low = range.first().and_then(Value::as_f64).unwrap_or(0.0);
            let high = range.get(1).and_then(Value::as_f64).unwrap_or(1.0);
            Some(
                picker
                    .range_term(column, low, high)
                    .ok_or_else(|| bad("The column has no chart"))?,
            )
        } else {
            None
        };
        picker.set_term(column, term.as_deref());
        Ok(shown_now(&picker))
    });

    let s = shared.clone();
    let options = options.call("window", move |params, _call: &Call| {
        let picker = s.lock();
        let from = params["from"].as_u64().unwrap_or(0) as usize;
        let count = params["count"].as_u64().unwrap_or(100) as usize;
        let cursor = params["cursor"].as_u64().map(|id| id as usize);
        Ok(picker.window(from, count, cursor))
    });

    let s = shared.clone();
    let options = options.call("mark", move |params, _call: &Call| {
        let mut picker = s.lock();
        let on = params["on"].as_bool().unwrap_or(true);
        picker.set_marked(ids_of(&params, "ids"), on);
        Ok(picker.summary())
    });

    let s = shared.clone();
    let options = options.call("mark_range", move |params, _call: &Call| {
        let mut picker = s.lock();
        let (Some(from), Some(to)) = (params["from"].as_u64(), params["to"].as_u64()) else {
            return Err(bad("A run of rows is from a row to a row"));
        };
        picker.mark_range(
            from as usize,
            to as usize,
            params["on"].as_bool().unwrap_or(true),
        );
        Ok(picker.summary())
    });

    let s = shared.clone();
    let options = options.call("mark_shown", move |params, _call: &Call| {
        let mut picker = s.lock();
        picker.mark_shown(params["on"].as_bool().unwrap_or(true));
        Ok(picker.summary())
    });

    let s = shared.clone();
    let options = options.call("unmark_all", move |_params, _call: &Call| {
        let mut picker = s.lock();
        picker.unmark_all();
        Ok(picker.summary())
    });

    let s = shared.clone();
    let options = options.call("invert", move |_params, _call: &Call| {
        let mut picker = s.lock();
        picker.invert();
        Ok(picker.summary())
    });

    let s = shared.clone();
    let options = options.call("mark_value", move |params, _call: &Call| {
        let mut picker = s.lock();
        let column = column_of(&params, &picker)?;
        let value = match params["id"].as_u64() {
            Some(id) => picker
                .records
                .get(id as usize)
                .ok_or_else(|| bad("There is no such row"))?
                .cells
                .get(column)
                .cloned()
                .unwrap_or_default(),
            None => params["value"].as_str().unwrap_or_default().to_owned(),
        };
        let ids = picker.rows_with(column, &value, params["facet"].as_bool().unwrap_or(false));
        let count = ids.len();
        picker.set_marked(ids, true);
        Ok(json!({ "count": count, "summary": picker.summary() }))
    });

    let s = shared.clone();
    let options = options.call("column", move |params, _call: &Call| {
        let mut picker = s.lock();
        let column = column_of(&params, &picker)?;
        Ok(picker.facet(column))
    });

    let s = shared.clone();
    let r = run.clone();
    let options = options.call("output", move |params, _call: &Call| {
        let mut picker = s.lock();
        let fields = fields_of(&params);
        let shape = shape_of(&r, fields.as_deref());
        let cursor = params["cursor"].as_u64().map(|id| id as usize);
        let rows = to_send(&mut picker, &r, cursor);
        let again = again(&picker, &r, fields.as_deref());
        let mut out = json!({ "count": rows.len(), "again": again, "text": "" });
        match output::problem_of(&shape, &picker.names) {
            Some(problem) => out["error"] = json!(problem),
            None => {
                let records: Vec<_> = rows
                    .iter()
                    .take(OUTPUT_ROWS)
                    .map(|&id| &picker.records[id as usize])
                    .collect();
                out["text"] = json!(output::render(&records, &shape, &picker.source()));
            }
        }
        Ok(out)
    });

    let s = shared.clone();
    let options = options.call("copy_row", move |params, _call: &Call| {
        let picker = s.lock();
        let record = params["id"]
            .as_u64()
            .and_then(|id| picker.records.get(id as usize))
            .ok_or_else(|| bad("There is no such row"))?;
        let text = match params["column"].as_u64() {
            Some(column) => record
                .cells
                .get(column as usize)
                .cloned()
                .unwrap_or_default(),
            None => record.cells.join("\t"),
        };
        Ok(json!({ "text": text }))
    });

    let options = match run.preview.clone() {
        None => options,
        Some(template) => {
            let s = shared.clone();
            options.call("preview", move |params, call: &Call| {
                let command = {
                    let picker = s.lock();
                    let record = params["id"]
                        .as_u64()
                        .and_then(|id| picker.records.get(id as usize))
                        .ok_or_else(|| bad("There is no such row"))?;
                    preview::command_for(&template, record, &picker.source())
                };
                let width = params["width"].as_u64().unwrap_or(80).clamp(10, 1000) as u32;
                let result = preview::run(&command, width, &|| call.is_cancelled());
                Ok(json!({
                    "text": result.text,
                    "status": result.status,
                    "cut": result.cut,
                    "timed_out": result.timed_out,
                }))
            })
        }
    };

    let s = shared.clone();
    let c = control.clone();
    let options = options.call("cancel", move |_params, _call: &Call| {
        *s.cancelled
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
        close_soon(&c);
        Ok(json!({}))
    });

    let s = shared.clone();
    let r = run.clone();
    let c = control.clone();
    options.call("choose", move |params, _call: &Call| {
        let mut picker = s.lock();
        let fields = fields_of(&params);
        let shape = shape_of(&r, fields.as_deref());
        if let Some(problem) = output::problem_of(&shape, &picker.names) {
            return Err(ViewError::with_message("bad-shape", problem));
        }
        let rows: Vec<u32> = if params["marked"].as_bool() == Some(true) {
            picker.marked_ids()
        } else {
            let mut seen = std::collections::HashSet::new();
            ids_of(&params, "ids")
                .into_iter()
                .filter(|&id| id < picker.records.len() && seen.insert(id))
                .map(|id| id as u32)
                .collect()
        };
        if rows.is_empty() {
            return Err(ViewError::with_message("nothing", "No row was chosen"));
        }
        let count = rows.len();
        *s.answer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some((rows, shape));
        close_soon(&c);
        Ok(json!({ "sent": count }))
    })
}
