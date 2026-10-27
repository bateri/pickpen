// What goes out on stdout for the rows chosen, in each shape (from test/output.test.ts).

use super::*;
use crate::input::{Reader, Sink};

struct Table {
    records: Vec<Record>,
    format: Option<Format>,
    names: Vec<String>,
    heading: Option<String>,
}

impl Sink for Table {
    fn columns(&mut self, names: Vec<String>, heading: Option<String>) {
        self.names = names;
        if heading.is_some() {
            self.heading = heading;
        }
    }
    fn record(&mut self, record: Record) {
        self.records.push(record);
    }
    fn problem(&mut self, _: String) {}
}

impl Table {
    fn source(&self) -> Source<'_> {
        Source {
            format: self.format,
            names: &self.names,
            heading: self.heading.as_deref(),
        }
    }

    fn all(&self) -> Vec<&Record> {
        self.records.iter().collect()
    }

    fn render(&self, shape: &Shape) -> String {
        render(&self.all(), shape, &self.source(), false)
    }
}

fn table(text: &str) -> Table {
    let mut t = Table {
        records: Vec::new(),
        format: None,
        names: Vec::new(),
        heading: None,
    };
    let mut reader = Reader::new(crate::input::Cut::default());
    reader.feed(text, &mut t);
    reader.end(&mut t);
    t.format = reader.format();
    t
}

fn csv() -> Table {
    table("name,note\nann,\"a, b\"\nbob,plain\n")
}
fn pods() -> Table {
    table("NAME     STATUS\nweb-1    Running\nweb-2    Error\n")
}
fn jsonl() -> Table {
    table("{\"a\":1,\"b\":\"x\"}\n{\"a\":2}\n")
}
fn lines_of() -> Table {
    table("a1b2c3d Fix the thing\n9f8e7d6 Add more\n")
}

fn fields(names: &[&str]) -> Shape {
    Shape::Fields(names.iter().map(|n| n.to_string()).collect())
}

#[test]
fn in_the_inputs_shape_a_row_goes_out_as_the_text_it_was_read_from() {
    let csv = csv();
    assert_eq!(
        csv.render(&Shape::Input),
        "name,note\nann,\"a, b\"\nbob,plain\n"
    );
    // A table's heading stays behind, so that what reads the rows is given only rows.
    let pods = pods();
    assert_eq!(
        render(&pods.all()[1..], &Shape::Input, &pods.source(), false),
        "web-2    Error\n"
    );
    let jsonl = jsonl();
    assert_eq!(
        jsonl.render(&Shape::Input),
        "{\"a\":1,\"b\":\"x\"}\n{\"a\":2}\n"
    );
    let json = table("[{\"a\":1},{\"a\":2},{\"a\":3}]");
    assert_eq!(
        render(
            &[&json.records[2], &json.records[0]],
            &Shape::Input,
            &json.source(),
            false
        ),
        "[\n  {\"a\":3},\n  {\"a\":1}\n]\n"
    );
    assert_eq!(
        crate::input::parse_json(&json.render(&Shape::Input)),
        Some(serde_json::json!([{ "a": 1 }, { "a": 2 }, { "a": 3 }]))
    );
}

#[test]
fn nothing_chosen_writes_nothing_at_all() {
    let csv = csv();
    for shape in [Shape::Input, Shape::As(As::Json), fields(&["note"])] {
        assert_eq!(render(&[], &shape, &csv.source(), false), "");
    }
}

#[test]
fn field_writes_columns_tab_separated_and_a_number_is_a_columns_place_or_a_lines_word() {
    let csv = csv();
    assert_eq!(
        csv.render(&fields(&["note", "name"])),
        "a, b\tann\nplain\tbob\n"
    );
    assert_eq!(csv.render(&fields(&["2"])), "a, b\nplain\n");
    let lines = lines_of();
    assert_eq!(lines.render(&fields(&["1"])), "a1b2c3d\n9f8e7d6\n");
    assert_eq!(
        part_of(&lines.records[0], "4", &lines.source()).as_deref(),
        Some("thing")
    );
    assert_eq!(
        part_of(&lines.records[0], "", &lines.source()).as_deref(),
        Some("a1b2c3d Fix the thing")
    );
    assert_eq!(part_of(&lines.records[0], "0", &lines.source()), None);
    assert_eq!(
        part_of(
            &lines.records[0],
            "99999999999999999999999",
            &lines.source()
        )
        .as_deref(),
        Some("")
    );
}

#[test]
fn format_fills_a_template_and_output_converts() {
    let pods = pods();
    assert_eq!(
        pods.render(&Shape::Template(
            "kubectl delete pod {NAME} # {2}".to_string()
        )),
        "kubectl delete pod web-1 # Running\nkubectl delete pod web-2 # Error\n"
    );
    assert_eq!(
        csv().render(&Shape::As(As::Tsv)),
        "name\tnote\nann\ta, b\nbob\tplain\n"
    );
    assert_eq!(
        pods.render(&Shape::As(As::Csv)),
        "NAME,STATUS\nweb-1,Running\nweb-2,Error\n"
    );
    assert_eq!(
        crate::input::parse_json(&pods.render(&Shape::As(As::Json))),
        Some(serde_json::json!([
            { "NAME": "web-1", "STATUS": "Running" },
            { "NAME": "web-2", "STATUS": "Error" },
        ]))
    );
    // JSON keeps the values it was given, not their text.
    assert_eq!(
        jsonl().render(&Shape::As(As::Jsonl)),
        "{\"a\":1,\"b\":\"x\"}\n{\"a\":2}\n"
    );
}

#[test]
fn a_shape_that_names_no_column_is_refused_before_anything_is_written() {
    let pods = pods();
    assert_eq!(
        problem_of(&fields(&["NAME", "nope"]), &pods.names).as_deref(),
        Some("There is no column named \"nope\"")
    );
    assert_eq!(
        problem_of(&Shape::Template("{NAME} {wat}".to_string()), &pods.names).as_deref(),
        Some("There is no column named \"wat\"")
    );
    assert_eq!(
        problem_of(&Shape::Template("{} {2} {name}".to_string()), &pods.names),
        None
    );
}

#[test]
fn rows_written_one_by_one_come_to_what_rendering_them_all_at_once_writes() {
    let cases = [
        (csv(), Shape::Input),
        (csv(), Shape::As(As::Csv)),
        (pods(), Shape::As(As::Tsv)),
        (pods(), fields(&["NAME"])),
        (jsonl(), Shape::Input),
    ];
    for (t, shape) in &cases {
        assert!(streams(shape, t.format));
        for nul in [false, true] {
            let mut piecewise = head(shape, &t.source(), nul);
            for r in &t.records {
                piecewise += &one(r, shape, &t.source(), nul);
            }
            assert_eq!(piecewise, render(&t.all(), shape, &t.source(), nul));
        }
    }
    assert!(!streams(&Shape::As(As::Json), Some(Format::Csv)));
}

#[test]
fn print0_ends_each_row_with_nul_and_a_document_is_one_row() {
    let lines = table("one\ntwo words\n");
    assert_eq!(
        render(&lines.all(), &Shape::Input, &lines.source(), true),
        "one\0two words\0"
    );
    let csv = csv();
    assert_eq!(
        render(&csv.all(), &Shape::Input, &csv.source(), true),
        "name,note\0ann,\"a, b\"\0bob,plain\0"
    );
    let json = table("[{\"a\":1},{\"a\":2}]");
    assert_eq!(
        render(&json.all(), &Shape::Input, &json.source(), true),
        "[\n  {\"a\":1},\n  {\"a\":2}\n]\0"
    );
}

#[test]
fn a_template_reads_braces_as_javascript_did() {
    let pods = pods();
    let shape = Shape::Template("{{NAME}} {NA{ME} {} {".to_string());
    assert_eq!(
        render(&pods.all()[..1], &shape, &pods.source(), false),
        "{web-1} {NA web-1    Running {\n"
    );
}

#[test]
fn csv_quotes_what_it_must() {
    let t = table("a\tb\n x\tsay \"hi\"\n");
    assert_eq!(
        t.render(&Shape::As(As::Csv)),
        "a,b\n\" x\",\"say \"\"hi\"\"\"\n"
    );
    let numbers = table("{\"2\":\"b\",\"1\":\"a\"}\n");
    assert_eq!(
        numbers.render(&Shape::As(As::Jsonl)),
        "{\"1\":\"a\",\"2\":\"b\"}\n"
    );
}
