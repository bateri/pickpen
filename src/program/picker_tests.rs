// The rows shown and the rows that go out, in their order: with more rows than one core looks
// through, and rows that come after the order was chosen.

use super::*;

/// A row's `CPU`: a hundred and one values, so that most rows tie with others.
fn cpu(id: usize) -> u32 {
    (id * 7919 % 101) as u32
}

fn add(picker: &mut Picker, ids: std::ops::Range<usize>) {
    for id in ids {
        let cells = vec![format!("pod-{id}"), cpu(id).to_string()];
        picker.record(Record {
            raw: cells.join(","),
            cells,
            value: None,
        });
    }
}

fn picker(rows: usize) -> Picker {
    let mut picker = Picker::new("", None, false);
    picker.columns(vec!["NAME".into(), "CPU".into()], None);
    add(&mut picker, 0..rows);
    picker
}

/// The rows whose `CPU` is above 50, highest first, ties in the input's order.
fn busiest(rows: usize) -> Vec<u32> {
    let mut ids: Vec<u32> = (0..rows as u32)
        .filter(|&id| cpu(id as usize) > 50)
        .collect();
    ids.sort_by_key(|&id| (std::cmp::Reverse(cpu(id as usize)), id));
    ids
}

#[test]
fn a_query_keeps_the_rows_in_the_order_chosen() {
    let rows = 3 * ROWS_PER_CORE;
    let mut picker = picker(rows);
    picker.set_order(Some(Order {
        column: 1,
        descending: true,
    }));
    picker.set_query("CPU>50");
    assert_eq!(picker.shown, busiest(rows));
    picker.set_query("");
    assert_eq!(picker.shown.len(), rows);
    picker.set_query("CPU>50");
    assert_eq!(picker.shown, busiest(rows));
}

#[test]
fn rows_that_come_after_the_order_take_their_places() {
    let mut picker = picker(3 * ROWS_PER_CORE);
    picker.set_order(Some(Order {
        column: 1,
        descending: true,
    }));
    picker.set_query("CPU>50");
    let rows = 5 * ROWS_PER_CORE;
    add(&mut picker, 3 * ROWS_PER_CORE..rows);
    picker.refilter();
    assert_eq!(picker.shown, busiest(rows));
}

#[test]
fn without_an_order_the_rows_keep_the_input_s() {
    let rows = 3 * ROWS_PER_CORE;
    let mut picker = picker(rows);
    picker.set_query("CPU>50");
    let wanted: Vec<u32> = (0..rows as u32)
        .filter(|&id| cpu(id as usize) > 50)
        .collect();
    assert_eq!(picker.shown, wanted);
}

#[test]
fn the_marked_rows_go_out_in_the_order_shown() {
    let rows = 3 * ROWS_PER_CORE;
    let mut picker = picker(rows);
    picker.set_order(Some(Order {
        column: 1,
        descending: true,
    }));
    picker.set_marked((0..rows).filter(|id| cpu(*id) > 50), true);
    assert_eq!(picker.marked_ids(), busiest(rows));
}
