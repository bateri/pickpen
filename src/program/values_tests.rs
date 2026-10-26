// The quantities the query compares (from test/query.test.ts), and the JavaScript ways of
// writing numbers and moments that what goes out keeps.

use super::*;

fn q(kind: Kind, value: f64) -> Option<Quantity> {
    Some(Quantity { kind, value })
}

#[test]
fn a_quantity_is_read_from_what_a_cell_says() {
    assert_eq!(quantity("12"), q(Kind::Number, 12.0));
    assert_eq!(quantity("12.5%"), q(Kind::Number, 12.5));
    assert_eq!(quantity("1.5G"), q(Kind::Size, 1.5 * 1024f64.powi(3)));
    assert_eq!(quantity("512Ki"), q(Kind::Size, 512.0 * 1024.0));
    assert_eq!(quantity("3.4 MB"), q(Kind::Size, 3.4e6));
    assert_eq!(quantity("10k"), q(Kind::Size, 10240.0));
    assert_eq!(quantity("3m"), q(Kind::Duration, 180.0));
    assert_eq!(quantity("5d2h"), q(Kind::Duration, 5.0 * 86400.0 + 7200.0));
    assert_eq!(quantity("500ms"), q(Kind::Duration, 0.5));
    assert_eq!(quantity("1:02:03"), q(Kind::Duration, 3723.0));
    assert_eq!(quantity("2026-10-22").map(|q| q.kind), Some(Kind::Date));
    // Date.parse("2026-10-22T10:00:00Z")
    assert_eq!(
        quantity("2026-10-22T10:00:00Z").map(|q| q.value),
        Some(1_792_663_200_000.0)
    );
    for words in ["Running", "1.2.3", "v2", "", "a1b2", "-", "12 apples"] {
        assert_eq!(quantity(words), None, "{words}");
    }
}

#[test]
fn the_other_forms_read_as_javascript_reads_them() {
    assert_eq!(quantity(" +1. "), q(Kind::Number, 1.0));
    assert_eq!(quantity("-.5e-3"), q(Kind::Number, -0.0005));
    assert_eq!(quantity("1.e5"), q(Kind::Number, 100_000.0));
    assert_eq!(quantity("5 %"), q(Kind::Number, 5.0));
    assert_eq!(quantity("5\u{A0}MB"), q(Kind::Size, 5e6));
    assert_eq!(quantity("2b"), q(Kind::Size, 2.0));
    assert_eq!(quantity("2bb"), None);
    assert_eq!(quantity("2KiB"), q(Kind::Size, 2048.0));
    assert_eq!(quantity("2kB"), q(Kind::Size, 2000.0));
    assert_eq!(quantity("2M"), q(Kind::Size, 2.0 * 1024.0 * 1024.0));
    assert_eq!(quantity("1h30m"), q(Kind::Duration, 5400.0));
    assert_eq!(quantity("1.5.5s"), None);
    assert_eq!(quantity("0:01.23"), q(Kind::Duration, 1.23));
    assert_eq!(quantity("1:2"), None);
    assert_eq!(
        quantity("2026-02-30").map(|q| q.value),
        Some(1_772_409_600_000.0)
    );
    assert_eq!(quantity("2026-13-01"), None);
    assert_eq!(
        quantity("2026-10-22T24:00Z").map(|q| q.value),
        Some(1_792_713_600_000.0)
    );
    assert_eq!(quantity("2026-10-22T24:00:01Z"), None);
    assert_eq!(
        quantity("2026-10-22T10:00+0530").map(|q| q.value),
        Some(1_792_643_400_000.0)
    );
    assert_eq!(
        quantity("2026-10-22T10:00:00.9999Z").map(|q| q.value),
        Some(1_792_663_200_999.0)
    );
    assert_eq!(quantity("2026-10-22T10:00+24:00"), None);
    assert_eq!(
        quantity("0000-01-01").map(|q| q.value),
        Some(-62_167_219_200_000.0)
    );
    assert_eq!(quantity(&"1".repeat(41)), None);
}

#[test]
fn a_columns_kind_is_what_most_of_its_cells_are() {
    let kind = |cells: &[&str]| column_kind(cells.iter().copied());
    assert_eq!(kind(&["1", "2", "3", "4", "x"]), Some(Kind::Number));
    assert_eq!(kind(&["1", "2", "x", "y"]), None);
    assert_eq!(kind(&["1G", "0", "300M", "2G", "5G"]), Some(Kind::Size));
    assert_eq!(kind(&["Running", "Pending", "3"]), None);
    assert_eq!(kind(&[]), None);
}

#[test]
fn a_quantity_is_written_back_as_a_query_reads_it() {
    assert_eq!(write_quantity(Kind::Size, 1.5 * 1024f64.powi(3)), "1.5Gi");
    assert_eq!(write_quantity(Kind::Duration, 5400.0), "1.5h");
    assert_eq!(write_quantity(Kind::Number, 1234.567), "1230");
    for (kind, value) in [
        (Kind::Size, 3.0 * 1024f64.powi(2)),
        (Kind::Duration, 90.0),
        (Kind::Number, 0.25),
    ] {
        assert_eq!(
            quantity(&write_quantity(kind, value)).map(|q| q.value),
            Some(value)
        );
    }
    // As (n).toPrecision(3) rounds: a tie away from zero.
    assert_eq!(write_quantity(Kind::Number, 1.125), "1.13");
    assert_eq!(write_quantity(Kind::Number, -1.125), "-1.13");
    assert_eq!(write_quantity(Kind::Number, 999.6), "1000");
    assert_eq!(write_quantity(Kind::Number, 0.000123456), "0.000123");
    assert_eq!(write_quantity(Kind::Size, 100.0), "100B");
    assert_eq!(write_quantity(Kind::Duration, 0.0025), "3ms");
    assert_eq!(write_quantity(Kind::Duration, -0.0025), "-2ms");
    assert_eq!(
        write_quantity(Kind::Date, 1_792_627_200_000.0),
        "2026-10-22"
    );
    assert_eq!(
        write_quantity(Kind::Date, 1_792_663_200_500.0),
        "2026-10-22T10:00:00Z"
    );
}

#[test]
fn numbers_are_written_as_javascript_writes_them() {
    let cases: [(f64, &str); 16] = [
        (0.0, "0"),
        (-0.0, "0"),
        (1.0, "1"),
        (-1.5, "-1.5"),
        (0.1 + 0.2, "0.30000000000000004"),
        (1e21, "1e+21"),
        (1e20, "100000000000000000000"),
        (123_456_789_012_345_680_000.0, "123456789012345680000"),
        (1e-7, "1e-7"),
        (0.000001, "0.000001"),
        (123e-20, "1.23e-18"),
        (1.5e300, "1.5e+300"),
        (9_007_199_254_740_994.0, "9007199254740994"),
        (f64::NAN, "NaN"),
        (f64::INFINITY, "Infinity"),
        (5e-324, "5e-324"),
    ];
    for (n, text) in cases {
        assert_eq!(js_number(n), text);
    }
}

#[test]
fn javascript_spaces_and_lengths() {
    assert_eq!(js_trim("\u{FEFF}\u{A0} a \u{2028}"), "a");
    assert_eq!(js_trim("\u{85}a"), "\u{85}a");
    assert_eq!(utf16_len("a\u{1F600}é"), 4);
    assert_eq!(iso_string(-500.0), "1969-12-31T23:59:59.500Z");
    assert_eq!(iso_string(f64::NAN), "Invalid Date");
}
