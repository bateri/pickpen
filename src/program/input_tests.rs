// Reading the input (from test/input.test.ts): its shape from the first lines, a table lined up
// with spaces cut into its columns as the commands that print them line them up, and each record
// keeping the text it was read from.

use super::*;

#[derive(Default)]
struct Out {
    names: Vec<String>,
    heading: Option<String>,
    records: Vec<Record>,
    problems: Vec<String>,
    format: Option<Format>,
    finished: bool,
}

impl Sink for Out {
    fn format(&mut self, format: Format) {
        self.format = Some(format);
    }
    fn columns(&mut self, names: Vec<String>, heading: Option<String>) {
        self.names = names;
        if heading.is_some() {
            self.heading = heading;
        }
    }
    fn record(&mut self, record: Record) {
        self.records.push(record);
    }
    fn problem(&mut self, text: String) {
        self.problems.push(text);
    }
    fn finish(&mut self) {
        self.finished = true;
    }
}

impl Out {
    fn cells(&self) -> Vec<Vec<String>> {
        self.records.iter().map(|r| r.cells.clone()).collect()
    }
}

/// Reads text as pickpen reads stdin, in pieces of `piece` characters.
fn read_in(text: &str, format: Option<Format>, piece: usize) -> Out {
    let mut out = Out::default();
    let mut reader = Reader::new(Cut::shape(format));
    let chars: Vec<char> = text.chars().collect();
    for part in chars.chunks(piece) {
        reader.feed(&part.iter().collect::<String>(), &mut out);
    }
    reader.end(&mut out);
    assert_eq!(out.format, reader.format());
    out
}

fn read_text(text: &str) -> Out {
    read_in(text, None, 7)
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

const DOCKER: &str = "CONTAINER ID   IMAGE          COMMAND                  CREATED        STATUS                    PORTS                    NAMES
4f1c2a9e7b3d   nginx:1.27     \"/docker-entrypoint.…\"   2 hours ago    Up 2 hours                0.0.0.0:8080->80/tcp     web
9a8b7c6d5e4f   postgres:16    \"docker-entrypoint.s…\"   3 days ago     Up 3 days (healthy)       5432/tcp                 db
1a2b3c4d5e6f   redis:7        \"redis-server\"           3 days ago     Exited (0) 2 hours ago                             cache
";

const KUBECTL: &str = "NAME                      READY   STATUS             RESTARTS       AGE
api-7d9f8b6c5d-2xkqp      1/1     Running            0              3d4h
api-7d9f8b6c5d-9hjzt      1/1     Running            2 (5h ago)     3d4h
worker-5c6b7d8f9-k2m4n    0/1     CrashLoopBackOff   14 (2m ago)    47m
";

const DF: &str = "Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounted on
/dev/disk3s1s1   926Gi    10Gi   612Gi     2%    426k  4.3G    0%   /
devfs            204Ki   204Ki     0Bi   100%     706     0  100%   /dev
/dev/disk3s6     926Gi    20Ki   612Gi     1%       0  6.4G    0%   /System/Volumes/VM
";

const PS: &str = "USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED       TIME COMMAND
deployer         71234  12.3  1.1 412345678 182736   ??  S    10:01AM   1:02.33 /Applications/Safari.app/Contents/MacOS/Safari
root               123   0.0  0.0 408123456   1234   ??  Ss   Mon09AM   0:00.12 /usr/sbin/syslogd
_windowserver     1534   4.1  0.7 413456789 123456   ??  Ss   Mon09AM  52:10.45 /System/Library/WindowServer -daemon
";

#[test]
fn the_shape_is_read_from_the_first_lines() {
    let d = |text: &str| detect(text, true);
    assert_eq!(d(DOCKER), Format::Columns);
    assert_eq!(d(KUBECTL), Format::Columns);
    assert_eq!(d(DF), Format::Columns);
    assert_eq!(d(PS), Format::Columns);
    assert_eq!(
        d(
            "COMMAND   PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME\nnode    12345 me   21u  IPv4 0x1a2b      0t0  TCP *:3000 (LISTEN)\n"
        ),
        Format::Columns
    );
    assert_eq!(
        d("/usr/bin/a /usr/lib\n/usr/bin/b /usr/lib\n"),
        Format::Lines
    );
    assert_eq!(d("name,age\nann,3\nbob,4\n"), Format::Csv);
    assert_eq!(d("name\tage\nann\t3\n"), Format::Tsv);
    assert_eq!(d("{\"a\":1}\n{\"a\":2}\n"), Format::Jsonl);
    assert_eq!(d("[{\"a\":1},\n{\"a\":2}]\n"), Format::Json);
    assert_eq!(d("{\n  \"items\": []\n}\n"), Format::Json);
    assert_eq!(
        d("a1b2c3d Fix the thing\n9f8e7d6 Add the other, and more\n"),
        Format::Lines
    );
    assert_eq!(
        d("total 48\ndrwxr-xr-x  5 me staff 160 Oct 22 10:00 src\n"),
        Format::Lines
    );
    assert_eq!(
        d("[2026-10-22 10:00:01] started\n[2026-10-22 10:00:02] ready\n"),
        Format::Lines
    );
    assert_eq!(d("just one line\n"), Format::Lines);
    assert_eq!(d(""), Format::Lines);
}

#[test]
fn dockers_columns_hold_values_with_spaces_of_their_own() {
    let out = read_text(DOCKER);
    assert_eq!(
        out.names,
        strings(&[
            "CONTAINER ID",
            "IMAGE",
            "COMMAND",
            "CREATED",
            "STATUS",
            "PORTS",
            "NAMES"
        ])
    );
    let cells = out.cells();
    assert_eq!(
        cells[0],
        strings(&[
            "4f1c2a9e7b3d",
            "nginx:1.27",
            "\"/docker-entrypoint.…\"",
            "2 hours ago",
            "Up 2 hours",
            "0.0.0.0:8080->80/tcp",
            "web",
        ])
    );
    assert_eq!(cells[1][4], "Up 3 days (healthy)");
    assert_eq!(
        cells[2][4..],
        strings(&["Exited (0) 2 hours ago", "", "cache"])
    );
}

#[test]
fn kubectls_restarts_keep_when_they_were() {
    let out = read_text(KUBECTL);
    assert_eq!(
        out.names,
        strings(&["NAME", "READY", "STATUS", "RESTARTS", "AGE"])
    );
    let cells = out.cells();
    assert_eq!(
        cells[1],
        strings(&[
            "api-7d9f8b6c5d-9hjzt",
            "1/1",
            "Running",
            "2 (5h ago)",
            "3d4h"
        ])
    );
    assert_eq!(
        cells[2],
        strings(&[
            "worker-5c6b7d8f9-k2m4n",
            "0/1",
            "CrashLoopBackOff",
            "14 (2m ago)",
            "47m"
        ])
    );
}

#[test]
fn dfs_right_aligned_numbers_and_its_heading_of_two_words() {
    let out = read_text(DF);
    assert_eq!(
        out.names,
        strings(&[
            "Filesystem",
            "Size",
            "Used",
            "Avail",
            "Capacity",
            "iused",
            "ifree",
            "%iused",
            "Mounted on",
        ])
    );
    let cells = out.cells();
    assert_eq!(
        cells[1],
        strings(&[
            "devfs", "204Ki", "204Ki", "0Bi", "100%", "706", "0", "100%", "/dev"
        ])
    );
    assert_eq!(cells[2][8], "/System/Volumes/VM");
}

#[test]
fn pss_last_column_takes_the_rest_of_the_line_spaces_and_all() {
    let out = read_text(PS);
    assert_eq!(out.names.last().map(String::as_str), Some("COMMAND"));
    assert_eq!(out.names[1], "PID");
    let cells = out.cells();
    let pids: Vec<&str> = cells.iter().map(|c| c[1].as_str()).collect();
    assert_eq!(pids, ["71234", "123", "1534"]);
    assert_eq!(
        cells[2].last().map(String::as_str),
        Some("/System/Library/WindowServer -daemon")
    );
    assert_eq!(cells[0][0], "deployer");
}

// As macOS prints it: a VSZ wider than its heading pushes the rest of the line to the right.
const PS_MAC: &str = "USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED      TIME COMMAND
_windowserver      394  45.9  1.0 104487033824 350624   ??  Rs   13Oct26 3046:43.05 /System/Library/WindowServer -daemon
someone          45283  39.3  0.5 1980409632 177600   ??  S    Wed12PM 738:52.90 /Applications/Browser.app/Contents/MacOS/Browser --type=renderer
root               123   0.0  0.0 408123456   1234   ??  Ss   Mon09AM   0:00.12 /usr/sbin/syslogd
";

#[test]
fn a_table_whose_wide_values_push_the_line_out_of_line_is_split_at_its_spaces() {
    assert_eq!(detect(PS_MAC, true), Format::Columns);
    let out = read_text(PS_MAC);
    assert_eq!(
        out.names,
        strings(&[
            "USER", "PID", "%CPU", "%MEM", "VSZ", "RSS", "TT", "STAT", "STARTED", "TIME",
            "COMMAND",
        ])
    );
    let cells = out.cells();
    assert_eq!(
        cells[0],
        strings(&[
            "_windowserver",
            "394",
            "45.9",
            "1.0",
            "104487033824",
            "350624",
            "??",
            "Rs",
            "13Oct26",
            "3046:43.05",
            "/System/Library/WindowServer -daemon",
        ])
    );
    assert_eq!(
        cells[1][10],
        "/Applications/Browser.app/Contents/MacOS/Browser --type=renderer"
    );
    let pids: Vec<&str> = cells.iter().map(|c| c[1].as_str()).collect();
    assert_eq!(pids, ["394", "45283", "123"]);
}

#[test]
fn a_later_line_wider_than_the_first_ones_is_cut_at_the_nearest_space() {
    let starts = column_starts("NAME    PID", &["ab      12"]);
    assert_eq!(starts, [0, 8]);
    assert_eq!(
        cut_columns("abcdefghij 1234", &starts),
        strings(&["abcdefghij", "1234"])
    );
    assert_eq!(
        cut_columns("ab    123456", &starts),
        strings(&["ab", "123456"])
    );
}

#[test]
fn csv_keeps_quoted_commas_and_line_breaks_and_each_records_own_text() {
    let text = "name,note\r\nann,\"a, b\"\r\nbob,\"two\nlines\"\ncat,\"say \"\"hi\"\"\"\n";
    let out = read_in(text, None, 3);
    assert_eq!(out.format, Some(Format::Csv));
    assert_eq!(out.names, strings(&["name", "note"]));
    assert_eq!(out.heading.as_deref(), Some("name,note"));
    assert_eq!(
        out.cells(),
        [
            strings(&["ann", "a, b"]),
            strings(&["bob", "two\nlines"]),
            strings(&["cat", "say \"hi\""]),
        ]
    );
    let raws: Vec<&str> = out.records.iter().map(|r| r.raw.as_str()).collect();
    assert_eq!(
        raws,
        [
            "ann,\"a, b\"",
            "bob,\"two\nlines\"",
            "cat,\"say \"\"hi\"\"\""
        ]
    );
}

#[test]
fn headings_are_made_unique_and_never_empty() {
    assert_eq!(
        read_text("a,,a,A\n1,2,3,4\n").names,
        strings(&["a", "column 2", "a 2", "A 3"])
    );
}

#[test]
fn json_lines_keys_are_columns_as_they_first_come_and_a_line_that_is_not_json_is_told() {
    let out = read_text("{\"a\":1,\"b\":{\"c\":2}}\nnot json\n{\"b\":null,\"d\":true}\n");
    assert_eq!(out.format, Some(Format::Jsonl));
    assert_eq!(out.names, strings(&["a", "b", "d"]));
    assert_eq!(
        out.cells(),
        [strings(&["1", "{\"c\":2}"]), strings(&["", "", "true"])]
    );
    assert_eq!(out.problems, strings(&["A line is not JSON"]));
    assert_eq!(
        out.records[1].value,
        Some(serde_json::json!({ "b": null, "d": true }))
    );
}

#[test]
fn a_json_document_is_its_array_or_the_one_array_of_objects_it_holds() {
    assert_eq!(
        read_text("[{\"x\":1},{\"x\":2}]").cells(),
        [strings(&["1"]), strings(&["2"])]
    );
    let kube = read_text(
        "{\"apiVersion\":\"v1\",\"items\":[{\"name\":\"a\"},{\"name\":\"b\"}],\"kind\":\"List\"}",
    );
    assert_eq!(kube.names, strings(&["name"]));
    assert_eq!(kube.cells(), [strings(&["a"]), strings(&["b"])]);
    assert_eq!(
        read_text("[1,2]").cells(),
        [strings(&["1"]), strings(&["2"])]
    );
    let bad = read_in("[1, 2", Some(Format::Json), 7);
    assert_eq!(
        bad.problems,
        strings(&["The input is not one JSON document"])
    );
}

#[test]
fn lines_blank_ones_skipped_colour_codes_and_cr_dropped() {
    let out = read_text("\x1b[32mone\x1b[0m\r\n\n  \ntwo\n");
    assert_eq!(out.format, Some(Format::Lines));
    assert_eq!(out.names, strings(&["line"]));
    let raws: Vec<&str> = out.records.iter().map(|r| r.raw.as_str()).collect();
    assert_eq!(raws, ["one", "two"]);
}

#[test]
fn input_decides_at_once_so_a_slow_first_line_is_not_waited_on() {
    let mut out = Out::default();
    let mut reader = Reader::new(Cut::shape(Some(Format::Lines)));
    reader.feed("first\n", &mut out);
    assert_eq!(reader.format(), Some(Format::Lines));
    let raws: Vec<&str> = out.records.iter().map(|r| r.raw.as_str()).collect();
    assert_eq!(raws, ["first"]);
}

#[test]
fn a_delimiter_cuts_lines_into_columns_by_place_the_last_taking_the_rest() {
    let mut out = Out::default();
    let mut reader = Reader::new(Cut {
        format: Some(Format::Split),
        delimiter: Some(":".to_string()),
        nul: false,
    });
    reader.feed(
        "src/a.rs:12:let url = \"http://x\";\nsrc/b.rs:3:fn main() {\nREADME\n",
        &mut out,
    );
    reader.end(&mut out);
    assert_eq!(out.names, strings(&["1", "2", "3"]));
    assert_eq!(
        out.cells(),
        [
            strings(&["src/a.rs", "12", "let url = \"http://x\";"]),
            strings(&["src/b.rs", "3", "fn main() {"]),
            strings(&["README"]),
        ]
    );
    assert_eq!(out.records[0].raw, "src/a.rs:12:let url = \"http://x\";");
}

#[test]
fn read0_ends_rows_at_nul_and_keeps_their_line_ends() {
    for format in [Format::Lines, Format::Split] {
        let mut out = Out::default();
        let mut reader = Reader::new(Cut {
            format: Some(format),
            delimiter: Some("/".to_string()),
            nul: true,
        });
        reader.feed("a/one\0b/two\nlines\0", &mut out);
        reader.end(&mut out);
        let raws: Vec<&str> = out.records.iter().map(|r| r.raw.as_str()).collect();
        assert_eq!(raws, ["a/one", "b/two\nlines"]);
    }
}

// Beyond the TypeScript's tests: what this port must keep of how Node read and wrote.

#[test]
fn colour_codes_go_and_what_only_looks_like_one_stays() {
    assert_eq!(plain("a\x1b]0;title\x07b\x1b]8;;x\x1b\\c"), "abc");
    assert_eq!(plain("a\x1b[1;2"), "a\x1b[1;2");
    assert_eq!(plain("a\x1b]x"), "ax");
    assert_eq!(plain("a\x1bMb\x1b[b"), "ab");
    assert_eq!(plain("a\x1b[c"), "a");
    assert_eq!(plain("a\x1b\x1bb"), "a\x1b\x1bb");
}

#[test]
fn json_reads_and_writes_as_javascript_does() {
    let value = parse_json("{\"b\":1,\"2\":2.0,\"a\":3e0,\"1\":4,\"01\":5,\"b\":8.5e-7}").unwrap();
    assert_eq!(
        stringify(&value),
        "{\"1\":4,\"2\":2,\"b\":8.5e-7,\"a\":3,\"01\":5}"
    );
    assert_eq!(
        stringify(&parse_json("[1e21, -0, 1E3, \"\\u0007\\u2028/é\\ud83d\\ude00\"]").unwrap()),
        "[1e+21,0,1000,\"\\u0007\u{2028}/é😀\"]"
    );
    assert_eq!(
        text_of(&parse_json("12345678901234567890").unwrap()),
        "12345678901234567000"
    );
    assert_eq!(
        parse_json("\"\\ud800x\""),
        Some(Value::String("\u{FFFD}x".to_string()))
    );
    for bad in [
        "01",
        "1.",
        ".5",
        "[1,]",
        "{\"a\":1,}",
        "'a'",
        "\"a\nb\"",
        "\u{FEFF}1",
        "+1",
        "nul",
        "[1] x",
    ] {
        assert_eq!(parse_json(bad), None, "{bad}");
    }
    assert_eq!(parse_json(" \t\r\n[] "), Some(Value::Array(Vec::new())));
}

#[test]
fn bytes_that_are_not_utf8_are_read_as_node_reads_them() {
    let mut decoder = Decoder::default();
    let mut text = decoder.decode(b"a\xe2\x82");
    text += &decoder.decode(b"\xacb\xffc\xe2");
    text += &decoder.decode(b"Ad\xe2\x82");
    text += &decoder.end();
    assert_eq!(text, "a€b\u{FFFD}c\u{FFFD}Ad\u{FFFD}");
}

#[test]
fn read_streams_what_comes_and_finishes() {
    let input = std::io::Cursor::new(b"name,age\nann,3\nbob,4\n".to_vec());
    let mut out = Out::default();
    read(input, Cut::default(), &mut out).unwrap();
    assert_eq!(out.format, Some(Format::Csv));
    assert_eq!(
        out.cells(),
        [strings(&["ann", "3"]), strings(&["bob", "4"])]
    );
    assert!(out.finished);
}

#[test]
fn a_slow_input_is_decided_on_the_lines_it_has_sent() {
    // A pipe whose writer waits: the first line must come out before the second is written.
    let (mut send, receive) = pipe();
    let (said, heard) = std::sync::mpsc::channel::<String>();
    struct Tell(std::sync::mpsc::Sender<String>);
    impl Sink for Tell {
        fn columns(&mut self, _: Vec<String>, _: Option<String>) {}
        fn record(&mut self, record: Record) {
            let _ = self.0.send(record.raw);
        }
        fn problem(&mut self, _: String) {}
    }
    let reading = std::thread::spawn(move || read(receive, Cut::default(), &mut Tell(said)));
    use std::io::Write;
    send.write_all(b"ok one\n").unwrap();
    let first = heard.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(first, "ok one");
    send.write_all(b"two\n").unwrap();
    drop(send);
    assert_eq!(heard.recv_timeout(Duration::from_secs(5)).unwrap(), "two");
    reading.join().unwrap().unwrap();
}

/// A pipe of the operating system, as `tail -f | pickpen` gives one.
fn pipe() -> (std::fs::File, std::fs::File) {
    use std::os::fd::FromRawFd;
    let mut fds = [0; 2];
    // SAFETY: pipe writes two new descriptors into the array, which the files then own.
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    // SAFETY: the descriptors are new and owned by nothing else.
    unsafe {
        (
            std::fs::File::from_raw_fd(fds[1]),
            std::fs::File::from_raw_fd(fds[0]),
        )
    }
}
