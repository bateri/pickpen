//! The command line: what to read, what to do with it, and how what goes out is shaped.
//!
//! The options are read as Node's `util.parseArgs` read them for the first pickpen, strictly and
//! with the same words when something is wrong, so that a script that ran it runs this the same.
//! Lengths of arguments are counted in characters, where Node counted UTF-16 code units: they
//! differ only for an option of one character beyond U+FFFF, which is no option either way.

use crate::input::{Cut, FORMATS, Format, quote_json};
use crate::output::{As, Shape};
use crate::values::js_trim;

pub const USAGE: &str = "usage: pickpen [options] [FILE]

Choose rows in the middle of a pipeline: they come in on stdin (or from FILE),
you choose in the terminal pane, and the rows you chose go out on stdout.

  ps aux | pickpen --field PID | xargs kill
  kubectl get pods | pickpen --where 'STATUS!=Running' --confirm --field NAME

  -q, --query QUERY      start with QUERY typed
  -z, --fuzzy            plain words of the query match their letters in order,
                         gaps allowed (fzy finds fuzzy), best matches first
  -w, --where QUERY      no view: write the rows QUERY matches, as grep would
  -c, --confirm          a person confirms: the rows --where matches are marked,
                         and only marked rows go out
  -s, --sort [-]COLUMN   in COLUMN's order (with -, the other way)
  -f, --field COLUMN,…   write these columns of each row, tab-separated
      --format TEMPLATE  write each row as TEMPLATE: {COLUMN}, {2}, {} the row
  -o, --output FORMAT    write csv, tsv, json or jsonl
      --print0           end each row written with NUL, for xargs -0
  -i, --input FORMAT     read lines, csv, tsv, columns, jsonl or json
                         (without it, the shape is read from the first lines)
  -d, --delimiter SEP    read lines cut into columns 1, 2, … at SEP ('\\t' a tab),
                         the last taking the rest of the line: -d : for grep -n
      --read0            rows end at NUL, as find -print0 writes them
  -p, --preview COMMAND  show what COMMAND prints for the row the cursor is on;
                         {} {COLUMN} {2} stand for the row and its cells, {q} for
                         the query, {+} {+COLUMN} for the marked rows (or the row)
      --expect KEY,…     KEY sends too (ctrl-o, f5), and the first line written is
                         the key that sent, empty for Enter
  -t, --title TEXT       a line above the rows, saying what they are for
  -h, --help             this text
  -v, --version          the version

The query: words the row must hold, !word for one it must not, ^word and
word$ for a cell that starts or ends with it, and COLUMN=v, !=, ~ (holds),
!~, >, >=, <, <=, and a..b, with quantities read as such: cpu>50, size>1G,
age<2h. Every term must hold; a | alone between two keeps rows with either.
The same query does the same in the view and with --where.

Exit status: 0 rows went out, 1 none did, 2 a person was needed and there
was no terminal that shows pencere views, 64 the command line was wrong,
65 the input could not be read, 130 ⌃C.";

/// The input and output flags as the person gave them, for the command line the view shows.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Given {
    pub input: Option<String>,
    pub delimiter: Option<String>,
    pub read0: bool,
    pub field: Option<Vec<String>>,
    pub format: Option<String>,
    pub output: Option<String>,
    pub print0: bool,
}

/// `--sort`: the column, and whether the order is the other way (`-COLUMN`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sort {
    pub column: String,
    pub descending: bool,
}

/// What to do, as the command line says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Run {
    /// The file to read, or none for stdin (`-` is stdin too).
    pub file: Option<String>,
    pub query: String,
    /// `--fuzzy`: the query's plain words match letter by letter, and the rows go best first.
    pub fuzzy: bool,
    pub where_: Option<String>,
    pub confirm: bool,
    pub sort: Option<Sort>,
    pub shape: Shape,
    /// `--print0`: each row written ends with NUL rather than a line end.
    pub print0: bool,
    pub cut: Cut,
    pub preview: Option<String>,
    /// `--expect`: the keys besides Enter that send, as fzf names them (`ctrl-o`, `f5`).
    pub expect: Vec<String>,
    pub title: Option<String>,
    pub given: Given,
}

/// A key `--expect` takes, as fzf names it, and as the view's keys are written (`Ctrl-o`, `F5`):
/// ⌃ with a letter or a digit, or a function key. The others type, or are a terminal's own.
pub fn expect_keys(name: &str) -> Option<String> {
    if let Some(key) = name.strip_prefix("ctrl-")
        && key.len() == 1
        && key
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    {
        return Some(format!("Ctrl-{key}"));
    }
    let n: u8 = name.strip_prefix('f')?.parse().ok()?;
    ((1..=12).contains(&n) && name == format!("f{n}")).then(|| format!("F{n}"))
}

// Made once, so the size of `Run` costs nothing.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Parsed {
    Help,
    Version,
    Run(Run),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Text,
    Flag,
}

/// The options, as `parseArgs` was given them: long name, short name, kind, and whether it may
/// be given more than once.
const OPTIONS: [(&str, char, Kind, bool); 17] = [
    ("query", 'q', Kind::Text, false),
    ("fuzzy", 'z', Kind::Flag, false),
    ("where", 'w', Kind::Text, false),
    ("confirm", 'c', Kind::Flag, false),
    ("sort", 's', Kind::Text, false),
    ("field", 'f', Kind::Text, true),
    ("format", '\0', Kind::Text, false),
    ("output", 'o', Kind::Text, false),
    ("print0", '\0', Kind::Flag, false),
    ("input", 'i', Kind::Text, false),
    ("delimiter", 'd', Kind::Text, false),
    ("read0", '\0', Kind::Flag, false),
    ("preview", 'p', Kind::Text, false),
    ("expect", '\0', Kind::Text, true),
    ("title", 't', Kind::Text, false),
    ("help", 'h', Kind::Flag, false),
    ("version", 'v', Kind::Flag, false),
];

fn option(name: &str) -> Option<(&'static str, char, Kind, bool)> {
    OPTIONS.into_iter().find(|(long, ..)| *long == name)
}

/// The long name a short one stands for, or the short one itself when it stands for none.
fn long_for(short: char) -> String {
    OPTIONS
        .into_iter()
        .find(|(_, s, ..)| *s == short && short != '\0')
        .map_or_else(|| short.to_string(), |(long, ..)| long.to_string())
}

fn takes_text(name: &str) -> bool {
    option(name).is_some_and(|(_, _, kind, _)| kind == Kind::Text)
}

enum Token {
    Option {
        name: String,
        raw_name: String,
        value: Option<String>,
        /// Whether the value was written in the same argument (`--sort=-cpu`, `-fNAME`).
        inline: bool,
    },
    Positional(String),
}

/// `--sort -cpu` as `--sort=-cpu`: the minus is the order's, not an option's.
fn join_sort(argv: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < argv.len() {
        let arg = &argv[at];
        match argv.get(at + 1) {
            Some(next) if (arg == "--sort" || arg == "-s") && next.starts_with('-') => {
                out.push(format!("--sort={next}"));
                at += 2;
            }
            _ => {
                out.push(arg.clone());
                at += 1;
            }
        }
    }
    out
}

/// The arguments as `parseArgs` cuts them into options and positionals.
fn tokens_of(args: Vec<String>) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut rest: std::collections::VecDeque<String> = args.into();
    while let Some(arg) = rest.pop_front() {
        let chars: Vec<char> = arg.chars().collect();
        if arg == "--" {
            // Everything after a bare `--` is a positional.
            tokens.extend(rest.drain(..).map(Token::Positional));
            break;
        }
        let dashed = chars.len() > 2 && chars[0] == '-' && chars[1] != '-';
        if chars.len() == 2 && chars[0] == '-' && chars[1] != '-' {
            // `-f`, perhaps with its value after it.
            let name = long_for(chars[1]);
            let value = if takes_text(&name) {
                rest.pop_front()
            } else {
                None
            };
            tokens.push(Token::Option {
                name,
                raw_name: arg,
                value,
                inline: false,
            });
        } else if dashed && !takes_text(&long_for(chars[1])) {
            // `-abc` as `-a -b -c`; a short option that takes a value takes the rest (`-abfFILE`).
            let mut expanded = Vec::new();
            for at in 1..chars.len() {
                let short = chars[at];
                if !takes_text(&long_for(short)) || at == chars.len() - 1 {
                    expanded.push(format!("-{short}"));
                } else {
                    expanded.push(format!("-{}", chars[at..].iter().collect::<String>()));
                    break;
                }
            }
            for item in expanded.into_iter().rev() {
                rest.push_front(item);
            }
        } else if dashed {
            // `-fFILE`.
            tokens.push(Token::Option {
                name: long_for(chars[1]),
                raw_name: format!("-{}", chars[1]),
                value: Some(chars[2..].iter().collect()),
                inline: true,
            });
        } else if chars.len() > 2 && arg.starts_with("--") {
            let equals = arg.bytes().skip(3).any(|b| b == b'=');
            if !equals {
                // `--field`, perhaps with its value after it.
                let name = arg[2..].to_string();
                let value = if takes_text(&name) {
                    rest.pop_front()
                } else {
                    None
                };
                tokens.push(Token::Option {
                    name,
                    raw_name: arg,
                    value,
                    inline: false,
                });
            } else {
                // `--field=NAME`.
                let at = arg.find('=').unwrap_or(arg.len());
                let name = arg[2..at].to_string();
                let value = arg.get(at + 1..).unwrap_or("").to_string();
                tokens.push(Token::Option {
                    raw_name: format!("--{name}"),
                    name,
                    value: Some(value),
                    inline: true,
                });
            }
        } else {
            tokens.push(Token::Positional(arg));
        }
    }
    tokens
}

/// What the person gave, by option.
#[derive(Default)]
struct Values {
    texts: Vec<(&'static str, Vec<String>)>,
    flags: Vec<&'static str>,
}

impl Values {
    /// The last value given for an option.
    fn text(&self, name: &str) -> Option<String> {
        self.all(name).last().cloned()
    }

    fn all(&self, name: &str) -> &[String] {
        self.texts
            .iter()
            .find(|(n, _)| *n == name)
            .map_or(&[], |(_, v)| v.as_slice())
    }

    fn flag(&self, name: &str) -> bool {
        self.flags.contains(&name)
    }
}

/// `parseArgs` in its strict mode, with positionals allowed: what was given, or what is wrong.
fn parse_args(args: Vec<String>) -> Result<(Values, Vec<String>), String> {
    let mut values = Values::default();
    let mut positionals = Vec::new();
    for token in tokens_of(args) {
        let (name, raw_name, value, inline) = match token {
            Token::Positional(arg) => {
                positionals.push(arg);
                continue;
            }
            Token::Option {
                name,
                raw_name,
                value,
                inline,
            } => (name, raw_name, value, inline),
        };
        let Some((long, short, kind, _)) = option(&name) else {
            return Err(format!(
                "Unknown option '{raw_name}'. To specify a positional argument starting with a \
                 '-', place it at the end of the command after '--', as in '-- {}",
                quote_json(&raw_name)
            ));
        };
        let short_and_long = if short == '\0' {
            format!("--{long}")
        } else {
            format!("-{short}, --{long}")
        };
        match (kind, &value) {
            (Kind::Text, None) => {
                return Err(format!(
                    "Option '{short_and_long} <value>' argument missing"
                ));
            }
            (Kind::Flag, Some(_)) => {
                return Err(format!(
                    "Option '{short_and_long}' does not take an argument"
                ));
            }
            _ => {}
        }
        if let Some(value) = &value
            && !inline
            && value.chars().count() > 1
            && value.starts_with('-')
        {
            let example = if raw_name.starts_with("--") {
                format!("'{raw_name}=-XYZ'")
            } else {
                format!("'--{long}=-XYZ' or '{raw_name}-XYZ'")
            };
            return Err(format!(
                "Option '{raw_name}' argument is ambiguous.\nDid you forget to specify the \
                 option argument for '{raw_name}'?\nTo specify an option argument starting \
                 with a dash use {example}."
            ));
        }
        match value {
            Some(value) => match values.texts.iter_mut().find(|(n, _)| *n == long) {
                Some((_, given)) => given.push(value),
                None => values.texts.push((long, vec![value])),
            },
            None => values.flags.push(long),
        }
    }
    Ok((values, positionals))
}

/// The command line's arguments (without the program's name), or what is wrong with them.
pub fn parse(argv: &[String]) -> Result<Parsed, String> {
    let (values, positionals) = parse_args(join_sort(argv))?;
    if values.flag("help") {
        return Ok(Parsed::Help);
    }
    if values.flag("version") {
        return Ok(Parsed::Version);
    }
    if positionals.len() > 1 {
        return Err("give one FILE at most".to_string());
    }

    let fields: Vec<String> = values
        .all("field")
        .iter()
        .flat_map(|f| f.split(','))
        .map(|f| js_trim(f).to_string())
        .collect();
    if fields.iter().any(String::is_empty) {
        return Err("--field names a column with no name".to_string());
    }
    let format = values.text("format");
    let output = values.text("output");
    let shapes = [!fields.is_empty(), format.is_some(), output.is_some()];
    if shapes.iter().filter(|given| **given).count() > 1 {
        return Err("give one of --field, --format and --output".to_string());
    }
    let mut shape = Shape::Input;
    if !fields.is_empty() {
        shape = Shape::Fields(fields.clone());
    } else if let Some(template) = &format {
        shape = Shape::Template(template.clone());
    } else if let Some(output) = &output {
        let Some(to) = As::from_name(output) else {
            return Err(format!(
                "--output is csv, tsv, json or jsonl, not {}",
                quote_json(output)
            ));
        };
        shape = Shape::As(to);
    }

    let given_input = values.text("input");
    let mut input = None;
    if let Some(name) = &given_input {
        let Some(format) = Format::from_name(name) else {
            let names: Vec<&str> = FORMATS.iter().map(|f| f.name()).collect();
            return Err(format!("--input is one of {}", names.join(", ")));
        };
        input = Some(format);
    }
    let given_delimiter = values.text("delimiter");
    // `\t` as fzf and awk users write a tab.
    let delimiter = given_delimiter.as_deref().map(|d| match d {
        "\\t" => "\t".to_string(),
        d => d.to_string(),
    });
    if delimiter.as_deref() == Some("") {
        return Err("--delimiter is empty".to_string());
    }
    if delimiter.is_some() {
        if input.is_some() {
            return Err("give one of --input and --delimiter".to_string());
        }
        input = Some(Format::Split);
    }
    let read0 = values.flag("read0");
    if read0 {
        if let Some(name) = given_input.as_deref().filter(|name| *name != "lines") {
            return Err(format!(
                "--read0 reads lines, cut at --delimiter or not, not --input {name}"
            ));
        }
        input.get_or_insert(Format::Lines);
    }

    let mut sort = None;
    if let Some(given) = values.text("sort") {
        let descending = given.starts_with('-');
        let column = if descending {
            given[1..].to_string()
        } else {
            given
        };
        if column.is_empty() {
            return Err("--sort names no column".to_string());
        }
        sort = Some(Sort { column, descending });
    }

    let mut expect: Vec<String> = Vec::new();
    for name in values.all("expect").iter().flat_map(|e| e.split(',')) {
        let name = js_trim(name).to_lowercase();
        if expect_keys(&name).is_none() {
            return Err(format!(
                "--expect takes ctrl-<letter>, ctrl-<digit> or f1 to f12, not {}",
                quote_json(&name)
            ));
        }
        if !expect.contains(&name) {
            expect.push(name);
        }
    }

    let file = positionals.into_iter().next().filter(|file| file != "-");
    Ok(Parsed::Run(Run {
        file,
        query: values.text("query").unwrap_or_default(),
        fuzzy: values.flag("fuzzy"),
        where_: values.text("where"),
        confirm: values.flag("confirm"),
        sort,
        shape,
        print0: values.flag("print0"),
        cut: Cut {
            format: input,
            delimiter,
            nul: read0,
        },
        preview: values.text("preview"),
        expect,
        title: values.text("title"),
        given: Given {
            input: given_input,
            delimiter: given_delimiter,
            read0,
            field: if fields.is_empty() {
                None
            } else {
                Some(fields)
            },
            format,
            output,
            print0: values.flag("print0"),
        },
    }))
}

/// What went wrong with a file or a read, in the words Node said it in (`ENOENT: no such file or
/// directory`), which were libuv's. Node went on to name the call and the file (`, open 'FILE'`,
/// `, read`); this says only what went wrong.
pub fn os_words(error: &std::io::Error) -> String {
    let Some(errno) = error.raw_os_error() else {
        return error.to_string();
    };
    let words = ERRNO_WORDS.iter().find(|(n, ..)| *n == errno);
    match words {
        Some((_, code, said)) => format!("{code}: {said}"),
        None => {
            // Rust says `… (os error N)`: the words alone, as Node would have had them.
            let text = error.to_string();
            let text = text
                .split(" (os error")
                .next()
                .unwrap_or(&text)
                .to_lowercase();
            format!("Unknown system error {errno}: {text}")
        }
    }
}

#[cfg(unix)]
const ERRNO_WORDS: &[(i32, &str, &str)] = &[
    (libc::E2BIG, "E2BIG", "argument list too long"),
    (libc::EACCES, "EACCES", "permission denied"),
    (libc::EAGAIN, "EAGAIN", "resource temporarily unavailable"),
    (libc::EBADF, "EBADF", "bad file descriptor"),
    (libc::EBUSY, "EBUSY", "resource busy or locked"),
    (libc::ECONNRESET, "ECONNRESET", "connection reset by peer"),
    (libc::EEXIST, "EEXIST", "file already exists"),
    (
        libc::EFAULT,
        "EFAULT",
        "bad address in system call argument",
    ),
    (libc::EFBIG, "EFBIG", "file too large"),
    (libc::EINTR, "EINTR", "interrupted system call"),
    (libc::EINVAL, "EINVAL", "invalid argument"),
    (libc::EIO, "EIO", "i/o error"),
    (libc::EISDIR, "EISDIR", "illegal operation on a directory"),
    (libc::ELOOP, "ELOOP", "too many symbolic links encountered"),
    (libc::EMFILE, "EMFILE", "too many open files"),
    (libc::ENAMETOOLONG, "ENAMETOOLONG", "name too long"),
    (libc::ENFILE, "ENFILE", "file table overflow"),
    (libc::ENODEV, "ENODEV", "no such device"),
    (libc::ENOENT, "ENOENT", "no such file or directory"),
    (libc::ENOMEM, "ENOMEM", "not enough memory"),
    (libc::ENOSPC, "ENOSPC", "no space left on device"),
    (libc::ENOTDIR, "ENOTDIR", "not a directory"),
    (libc::ENXIO, "ENXIO", "no such device or address"),
    (libc::EPERM, "EPERM", "operation not permitted"),
    (libc::EPIPE, "EPIPE", "broken pipe"),
    (libc::EROFS, "EROFS", "read-only file system"),
    (libc::ESPIPE, "ESPIPE", "invalid seek"),
    (libc::ETIMEDOUT, "ETIMEDOUT", "connection timed out"),
    (libc::ETXTBSY, "ETXTBSY", "text file is busy"),
];

#[cfg(not(unix))]
const ERRNO_WORDS: &[(i32, &str, &str)] = &[];

#[cfg(test)]
#[path = "args_tests.rs"]
mod tests;
