// The command line (the parts of test/cli.test.ts that need no program running, and what
// Node's parseArgs said for the first pickpen).

use super::*;

fn parsed(args: &[&str]) -> Result<Parsed, String> {
    let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
    parse(&args)
}

fn options(args: &[&str]) -> Run {
    match parsed(args) {
        Ok(Parsed::Run(options)) => options,
        other => panic!("{args:?} gave {other:?}"),
    }
}

fn error(args: &[&str]) -> String {
    match parsed(args) {
        Err(message) => message,
        other => panic!("{args:?} gave {other:?}"),
    }
}

#[test]
fn the_command_line_is_checked_before_anything_is_read() {
    assert_eq!(
        error(&["--field", "A", "--output", "json"]),
        "give one of --field, --format and --output"
    );
    assert_eq!(
        error(&["--output", "xml"]),
        "--output is csv, tsv, json or jsonl, not \"xml\""
    );
    assert_eq!(
        error(&["--input", "yaml"]),
        "--input is one of lines, csv, tsv, columns, jsonl, json"
    );
    assert_eq!(error(&["a", "b"]), "give one FILE at most");
    assert_eq!(parsed(&["--help"]), Ok(Parsed::Help));
    assert_eq!(parsed(&["--version"]), Ok(Parsed::Version));
    assert!(USAGE.starts_with("usage: pickpen"));
}

#[test]
fn the_options_are_read_as_they_were_given() {
    let o = options(&[
        "-w",
        "STATUS!=Running",
        "--sort",
        "-cpu",
        "-f",
        "NAME, PID",
        "-f",
        "AGE",
        "-c",
        "file.txt",
    ]);
    assert_eq!(o.where_.as_deref(), Some("STATUS!=Running"));
    assert_eq!(
        o.sort,
        Some(Sort {
            column: "cpu".to_string(),
            descending: true
        })
    );
    let names: Vec<String> = ["NAME", "PID", "AGE"].map(String::from).to_vec();
    assert_eq!(o.shape, Shape::Fields(names.clone()));
    assert_eq!(o.given.field, Some(names));
    assert!(o.confirm);
    assert_eq!(o.file.as_deref(), Some("file.txt"));
    assert_eq!(o.query, "");

    let o = options(&[
        "-s",
        "-x",
        "--sort=y",
        "-iCSV".to_lowercase().as_str(),
        "-q",
        "web",
        "-",
    ]);
    assert_eq!(
        o.sort,
        Some(Sort {
            column: "y".to_string(),
            descending: false
        })
    );
    assert_eq!(o.cut.format, Some(Format::Csv));
    assert_eq!(o.given.input.as_deref(), Some("csv"));
    assert_eq!(o.query, "web");
    assert_eq!(o.file, None);

    let o = options(&[
        "--format",
        "{NAME}",
        "-t",
        "Kill which?",
        "-p",
        "echo {}",
        "--",
        "-file",
    ]);
    assert_eq!(o.shape, Shape::Template("{NAME}".to_string()));
    assert_eq!(o.given.format.as_deref(), Some("{NAME}"));
    assert_eq!(o.title.as_deref(), Some("Kill which?"));
    assert_eq!(o.preview.as_deref(), Some("echo {}"));
    assert_eq!(o.file.as_deref(), Some("-file"));

    let o = options(&["-o", "jsonl", "-cw", "x"]);
    assert_eq!(o.shape, Shape::As(As::Jsonl));
    assert_eq!(o.given.output.as_deref(), Some("jsonl"));
    assert!(o.confirm);
    assert_eq!(o.where_.as_deref(), Some("x"));
}

#[test]
fn a_delimiter_rows_ending_at_nul_and_rows_written_so() {
    let o = options(&["-d", ":", "--read0", "--print0"]);
    assert_eq!(
        o.cut,
        Cut {
            format: Some(Format::Split),
            delimiter: Some(":".to_string()),
            nul: true
        }
    );
    assert!(o.print0 && o.given.print0 && o.given.read0);
    assert_eq!(o.given.delimiter.as_deref(), Some(":"));
    assert_eq!(options(&["-d", "\\t"]).cut.delimiter.as_deref(), Some("\t"));
    assert_eq!(options(&["--read0"]).cut.format, Some(Format::Lines));
    assert_eq!(
        options(&["--read0", "-i", "lines"]).cut.format,
        Some(Format::Lines)
    );
    assert_eq!(
        error(&["-d", ":", "-i", "csv"]),
        "give one of --input and --delimiter"
    );
    assert_eq!(
        error(&["--read0", "-i", "json"]),
        "--read0 reads lines, cut at --delimiter or not, not --input json"
    );
    assert_eq!(error(&["-d", ""]), "--delimiter is empty");
}

#[test]
fn what_is_wrong_is_said_as_node_said_it() {
    assert_eq!(
        error(&["-x"]),
        "Unknown option '-x'. To specify a positional argument starting with a '-', place it at \
         the end of the command after '--', as in '-- \"-x\""
    );
    assert_eq!(
        error(&["--nope=1"]),
        "Unknown option '--nope'. To specify a positional argument starting with a '-', place it \
         at the end of the command after '--', as in '-- \"--nope\""
    );
    assert_eq!(
        error(&["--sort"]),
        "Option '-s, --sort <value>' argument missing"
    );
    assert_eq!(
        error(&["--format"]),
        "Option '--format <value>' argument missing"
    );
    assert_eq!(
        error(&["--confirm=yes"]),
        "Option '-c, --confirm' does not take an argument"
    );
    assert_eq!(
        error(&["--where", "-x"]),
        "Option '--where' argument is ambiguous.\nDid you forget to specify the option argument \
         for '--where'?\nTo specify an option argument starting with a dash use '--where=-XYZ'."
    );
    assert_eq!(
        error(&["-w", "-x"]),
        "Option '-w' argument is ambiguous.\nDid you forget to specify the option argument for \
         '-w'?\nTo specify an option argument starting with a dash use '--where=-XYZ' or \
         '-w-XYZ'."
    );
    assert_eq!(
        error(&["--field", " , A"]),
        "--field names a column with no name"
    );
    assert_eq!(error(&["--sort", "-"]), "--sort names no column");
    // Something wrong comes before --help.
    assert!(parsed(&["--help", "-x"]).is_err());
    assert_eq!(parsed(&["-w", "-", "--help"]), Ok(Parsed::Help));
}

#[test]
fn what_the_system_said_is_said_in_nodes_words() {
    let missing = std::fs::File::open("/no/such/file").unwrap_err();
    assert_eq!(os_words(&missing), "ENOENT: no such file or directory");
    let directory = std::io::Error::from_raw_os_error(libc::EISDIR);
    assert_eq!(
        os_words(&directory),
        "EISDIR: illegal operation on a directory"
    );
}
