// The query (from test/query.test.ts): what a person types chooses the rows they mean, in the
// view and with --where alike, since both run this code.

use super::*;

fn columns() -> Vec<String> {
    [
        "NAME",
        "STATUS",
        "%CPU",
        "SIZE",
        "AGE",
        "CONTAINER ID",
        "STARTED",
    ]
    .map(String::from)
    .to_vec()
}

fn row(cells: &[&str]) -> Row {
    Row::new(cells.iter().map(|c| c.to_string()).collect())
}

fn rows() -> Vec<Row> {
    vec![
        row(&[
            "web-1",
            "Running",
            "12.5",
            "1.2G",
            "3d4h",
            "a1b2",
            "2026-10-20",
        ]),
        row(&[
            "web-2",
            "CrashLoopBackOff",
            "0.0",
            "512Mi",
            "47m",
            "c3d4",
            "2026-10-22T08:00:00Z",
        ]),
        row(&[
            "db-1",
            "Running",
            "88",
            "40GiB",
            "45s",
            "e5f6",
            "2026-09-01",
        ]),
        row(&["cache", "Pending", "", "10MB", "2m", "Up 2 hours", ""]),
    ]
}

fn keep(query: &str) -> Vec<String> {
    let parsed = parse(query, &columns());
    rows()
        .into_iter()
        .filter(|r| row_matches(&parsed, r))
        .map(|r| r.cells[0].clone())
        .collect()
}

#[test]
fn words_are_looked_for_in_every_column_in_any_case_and_bang_word_leaves_rows_out() {
    assert_eq!(keep("web"), ["web-1", "web-2"]);
    assert_eq!(keep("RUNNING"), ["web-1", "db-1"]);
    assert_eq!(keep("!running"), ["web-2", "cache"]);
    assert_eq!(keep("web running"), ["web-1"]);
    assert_eq!(keep("\"up 2\""), ["cache"]);
    assert_eq!(keep(""), ["web-1", "web-2", "db-1", "cache"]);
}

#[test]
fn a_column_is_compared_by_its_heading_or_by_its_letters_alone() {
    assert_eq!(keep("status=running"), ["web-1", "db-1"]);
    assert_eq!(keep("STATUS=Running|Pending"), ["web-1", "db-1", "cache"]);
    assert_eq!(keep("STATUS!=Running"), ["web-2", "cache"]);
    assert_eq!(keep("name~WEB"), ["web-1", "web-2"]);
    assert_eq!(keep("name!~web"), ["db-1", "cache"]);
    assert_eq!(keep("cpu>50"), ["db-1"]);
    assert_eq!(keep("\"container id\"~up"), ["cache"]);
    assert_eq!(keep("containerid=e5f6"), ["db-1"]);
}

#[test]
fn quantities_compare_as_quantities_and_an_empty_cell_is_never_above_or_below() {
    assert_eq!(keep("%cpu<=12.5"), ["web-1", "web-2"]);
    assert_eq!(keep("size>1G"), ["web-1", "db-1"]);
    assert_eq!(keep("size=1.2G"), ["web-1"]);
    assert_eq!(keep("age<1h"), ["web-2", "db-1", "cache"]);
    assert_eq!(keep("age=1m..1h"), ["web-2", "cache"]);
    assert_eq!(keep("started>2026-10-01"), ["web-1", "web-2"]);
    // A bare number is read in the column's unit: a thousand bytes.
    assert_eq!(keep("size<20000000"), ["cache"]);
    // A value that is no quantity compares as text.
    assert_eq!(keep("name>e"), ["web-1", "web-2"]);
}

#[test]
fn a_name_that_is_no_columns_makes_the_term_a_word_and_is_told() {
    let lines = vec!["line".to_string()];
    let r = row(&["GET /a user=bob 200"]);
    assert!(row_matches(&parse("user=bob", &lines), &r));
    assert!(!row_matches(&parse("user=alice", &lines), &r));
    assert_eq!(
        unknown_names("user=bob line~GET size>1", &lines),
        ["user", "size"]
    );
    assert!(unknown_names("STATUS=x !foo", &columns()).is_empty());
}

#[test]
fn cells_sort_as_quantities_before_words_empty_cells_last_either_way() {
    let cells = ["10", "9", "", "b", "1.5G", "A", "2"];
    let mut up = cells.to_vec();
    up.sort_by(|a, b| compare_ordered(&sort_key(a), &sort_key(b), false));
    let mut down = cells.to_vec();
    down.sort_by(|a, b| compare_ordered(&sort_key(a), &sort_key(b), true));
    assert_eq!(up, ["2", "9", "10", "1.5G", "A", "b", ""]);
    assert_eq!(down, ["b", "A", "1.5G", "10", "9", "2", ""]);
    let before =
        |a: &str, b: &str| compare_ordered(&sort_key(a), &sort_key(b), false) == Ordering::Less;
    assert!(before("file9", "file10"));
    assert!(before("512Mi", "1G"));
}

#[test]
fn a_click_writes_its_term_into_the_query_in_place_of_the_columns_own() {
    let c = columns();
    assert_eq!(
        with_term("web STATUS=Running", &c, 1, Some("STATUS=Pending")),
        "web STATUS=Pending"
    );
    assert_eq!(
        with_term("web", &c, 1, Some("STATUS=Pending")),
        "web STATUS=Pending"
    );
    assert_eq!(with_term("STATUS=a web status!=b", &c, 1, None), "web");
    assert_eq!(with_term("", &c, 2, Some("%CPU=1..5")), "%CPU=1..5");
}

#[test]
fn terms_say_where_they_are_in_bytes() {
    let query = parse("é \"a b\" STATUS=x|y size=1..5", &columns());
    let places: Vec<(usize, usize)> = query.terms.iter().map(|t| (t.from(), t.to())).collect();
    assert_eq!(places, [(0, 2), (3, 8), (9, 19), (20, 29)]);
    let Term::Field {
        column, op, values, ..
    } = &query.terms[2]
    else {
        panic!("a field")
    };
    assert_eq!(
        (*column, *op, values.clone()),
        (1, Operator::Eq, vec!["x".to_string(), "y".to_string()])
    );
    let Term::Field { range, .. } = &query.terms[3] else {
        panic!("a field")
    };
    assert_eq!(*range, Some(("1".to_string(), "5".to_string())));
    assert_eq!(range_of("a...b"), None);
    assert_eq!(
        range_of("a.x..b"),
        Some(("a.x".to_string(), "b".to_string()))
    );
    assert_eq!(
        range_of("a..b..c"),
        Some(("a..b".to_string(), "c".to_string()))
    );
    assert_eq!(range_of("..b"), None);
}

#[test]
fn text_compares_with_its_numbers_by_value() {
    assert_eq!(compare_text("a01", "a1"), Ordering::Less);
    assert_eq!(compare_text("A", "a"), Ordering::Less);
    assert_eq!(compare_text("é2", "É10"), Ordering::Less);
    assert_eq!(compare_text("ab", "a"), Ordering::Greater);
    assert_eq!(simple_name("%CPU"), "cpu");
    assert_eq!(simple_name("नाम"), "नम");
    assert_eq!(quote_value("a b"), "\"a b\"");
    assert_eq!(quote_value("say \"hi\""), "'say \"hi\"'");
    assert_eq!(quote_name("NAME"), "NAME");
}

#[test]
fn a_word_may_be_at_a_cells_start_or_end_and_terms_joined_by_a_bar_are_either() {
    let none: [&str; 0] = [];
    assert_eq!(keep("^web"), ["web-1", "web-2"]);
    assert_eq!(keep("^eb"), none);
    assert_eq!(keep("-1$"), ["web-1", "db-1"]);
    assert_eq!(keep("^running$"), ["web-1", "db-1"]);
    assert_eq!(keep("^run$"), none);
    assert_eq!(keep("!^web"), ["db-1", "cache"]);
    // Quoted, they are the word's own.
    assert_eq!(keep("\"^web\""), none);
    assert_eq!(keep("^\"up 2\""), ["cache"]);
    assert_eq!(keep("\"hours$\""), none);
    assert_eq!(keep("cache | db"), ["db-1", "cache"]);
    assert_eq!(keep("web | db-1 running"), ["web-1", "db-1"]);
    assert_eq!(keep("STATUS=Pending | cpu>50"), ["db-1", "cache"]);
    assert_eq!(keep("crash | ^db | pending"), ["web-2", "db-1", "cache"]);
    assert_eq!(keep("\"|\""), none);
    assert_eq!(keep("| web |"), ["web-1", "web-2"]);
    // Alone, `^` and `$` are words.
    assert_eq!(keep("^ $"), none);

    let q = parse("a | !b c", &columns());
    assert_eq!(q.terms.len(), 2);
    assert_eq!((q.terms[0].from(), q.terms[0].to()), (0, 6));
    assert!(matches!(&q.terms[0], Term::Any { terms, .. } if terms.len() == 2));
}

fn keep_fuzzy(query: &str) -> Vec<String> {
    let parsed = parse_as(query, &columns(), true);
    rows()
        .into_iter()
        .filter(|r| row_matches(&parsed, r))
        .map(|r| r.cells[0].clone())
        .collect()
}

#[test]
fn with_fuzzy_a_plain_word_is_its_letters_in_order_and_the_best_match_scores_most() {
    let none: [&str; 0] = [];
    assert_eq!(keep_fuzzy("crshlp"), ["web-2"]);
    assert_eq!(keep_fuzzy("wbrun"), ["web-1"]);
    assert_eq!(keep_fuzzy("dbrun"), ["db-1"]);
    assert_eq!(keep_fuzzy("crshlp STATUS=Running"), none);
    // A word that is more than a word is as it was: quoted, !word, ^word, word$.
    assert_eq!(keep_fuzzy("\"wb\""), none);
    assert_eq!(keep_fuzzy("!wb"), ["web-1", "web-2", "db-1", "cache"]);
    assert_eq!(keep_fuzzy("^wb"), none);
    assert_eq!(keep_fuzzy("^web"), ["web-1", "web-2"]);
    assert!(parse_as("wb", &columns(), true).ranks());
    assert!(parse_as("x | wb", &columns(), true).ranks());
    assert!(!parse_as("\"wb\" STATUS=x", &columns(), true).ranks());
    assert!(!parse("wb", &columns()).ranks());

    assert_eq!(fuzzy_score("abc", "acb"), None);
    // A word's start, and letters that follow one another, count more.
    let query = |text: &str| fuzzy_score(text, "query").unwrap();
    assert!(query("src/query.rs") > query("q-u-e-r-y"));
    assert!(query("q-u-e-r-y") > query("xquery"));
    assert!(query("xquery") > query("qxuxexrxy"));
    let q = parse_as("query", &[], true);
    assert_eq!(q.score("src/query.rs"), query("src/query.rs"));
}
