//! `--preview`: the command run for the row the cursor is on, on the program's machine, with what
//! it prints shown beside the rows. Its braces are filled from the row, the query and the marked
//! rows (`command_for`).
//!
//! Every process of a pipeline shares the pane's terminal, and the terminal's answers to the program
//! arrive on it (pencere §13). So the command runs in a session of its own, with no controlling
//! terminal (`setsid`), and stdin from nowhere: it can neither read the terminal's input nor open
//! `/dev/tty`.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use crate::command::shell_quote;
use crate::input::Record;
use crate::output::{Source, part_of};

/// What the view is shown of a preview at most: more is cut, and the view says so.
const MAX_OUTPUT: usize = 256 * 1024;
const TIMEOUT: Duration = Duration::from_secs(10);

/// What a preview printed, and how it ended.
pub struct Preview {
    pub text: String,
    /// The command's status, or `None` when a signal ended it.
    pub status: Option<i32>,
    pub cut: bool,
    pub timed_out: bool,
}

/// What a command's braces are filled from: the row the cursor is on, the query, and the marked
/// rows, which are the cursor's row when none is marked (as fzf's `{+}` is).
pub struct Fill<'a> {
    pub record: &'a Record,
    pub query: &'a str,
    pub marked: &'a [&'a Record],
    pub source: Source<'a>,
}

/// What one `{…}` stands for, quoted for sh, or none for a name nothing has: `{}`, `{COLUMN}` and
/// `{2}` the row and its cells; `{q}` the query, whatever the columns are named; and `{+}`,
/// `{+COLUMN}` and `{+2}` the same of each marked row, a word each.
fn filled(name: &str, fill: &Fill<'_>) -> Option<String> {
    if name == "q" {
        return Some(shell_quote(fill.query));
    }
    let Some(name) = name.strip_prefix('+') else {
        return part_of(fill.record, name, &fill.source).map(|part| shell_quote(&part));
    };
    let rows = if fill.marked.is_empty() {
        std::slice::from_ref(&fill.record)
    } else {
        fill.marked
    };
    let parts: Option<Vec<String>> = rows
        .iter()
        .map(|record| part_of(record, name, &fill.source).map(|part| shell_quote(&part)))
        .collect();
    parts.map(|parts| parts.join(" "))
}

/// The command with each `{…}` filled (`filled`); one that names nothing is left as it is.
pub fn command_for(template: &str, fill: &Fill<'_>) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        let after = &rest[open + 1..];
        match after.find(['{', '}']) {
            Some(close) if after.as_bytes().get(close) == Some(&b'}') => {
                let name = &after[..close];
                out.push_str(&rest[..open]);
                match filled(name, fill) {
                    Some(part) => out.push_str(&part),
                    None => {
                        out.push('{');
                        out.push_str(name);
                        out.push('}');
                    }
                }
                rest = &after[close + 1..];
            }
            _ => {
                out.push_str(&rest[..=open]);
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Runs `command` with `sh -c`, `width` columns wide, until it ends, `TIMEOUT` passes or
/// `cancelled` says the view has moved on: then its whole process group is killed.
pub fn run(command: &str, width: u32, cancelled: &dyn Fn() -> bool) -> Preview {
    let mut child = match unsafe_session(
        Command::new("/bin/sh")
            .arg("-c")
            .arg(command)
            .env("COLUMNS", width.to_string())
            .env("LINES", "200")
            .env("PICKPEN_PREVIEW", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .spawn()
    {
        Ok(child) => child,
        Err(why) => {
            return Preview {
                text: why.to_string(),
                status: Some(127),
                cut: false,
                timed_out: false,
            };
        }
    };
    let pid = child.id();
    // Both streams go into one text, in the order they come.
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let mut readers = Vec::new();
    for stream in [
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    {
        let tx = tx.clone();
        readers.push(thread::spawn(move || {
            let mut stream = stream;
            let mut buffer = [0u8; 16 * 1024];
            while let Ok(n) = stream.read(&mut buffer) {
                if n == 0 || tx.send(buffer[..n].to_vec()).is_err() {
                    break;
                }
            }
        }));
    }
    drop(tx);
    let started = Instant::now();
    let mut bytes = Vec::new();
    let mut cut = false;
    let mut timed_out = false;
    let kill = || {
        // The command's whole group: a shell's children, a pager it started.
        if let Ok(group) = i32::try_from(pid) {
            // SAFETY: a plain call with a number; a group that is gone is answered ESRCH.
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
    };
    loop {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(chunk) => {
                let room = MAX_OUTPUT.saturating_sub(bytes.len());
                if chunk.len() > room {
                    cut = true;
                }
                bytes.extend_from_slice(&chunk[..chunk.len().min(room)]);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        if cancelled() {
            kill();
        } else if started.elapsed() > TIMEOUT && !timed_out {
            timed_out = true;
            kill();
        }
    }
    for reader in readers {
        let _ = reader.join();
    }
    let status = child.wait().ok().and_then(|status| status.code());
    Preview {
        text: String::from_utf8_lossy(&bytes).into_owned(),
        status,
        cut,
        timed_out,
    }
}

/// The command in a session of its own: no controlling terminal, its own process group.
#[allow(unsafe_code)]
fn unsafe_session(command: &mut Command) -> &mut Command {
    // SAFETY: `setsid` is async-signal-safe, and nothing else runs between fork and exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_braces_are_the_row_the_query_and_the_marked_rows_each_quoted() {
        let row = |raw: &str| Record {
            raw: raw.to_string(),
            cells: raw.split(' ').map(str::to_string).collect(),
            value: None,
        };
        let (cursor, one, two) = (row("a b"), row("c d"), row("it's e"));
        let names = ["q".to_string(), "x".to_string()];
        let source = Source {
            format: Some(crate::input::Format::Columns),
            names: &names,
            heading: None,
        };
        let marked = [&one, &two];
        let mut fill = Fill {
            record: &cursor,
            query: "a b",
            marked: &marked,
            source,
        };
        assert_eq!(
            command_for("show {} {x} {2} {q} {+} {+1} {nope}", &fill),
            "show 'a b' b b 'a b' 'c d' 'it'\\''s e' c 'it'\\''s' {nope}"
        );
        fill.marked = &[];
        assert_eq!(command_for("{+x}", &fill), "b");
    }

    #[test]
    fn a_preview_says_what_the_command_printed_and_how_it_ended() {
        let preview = run("printf 'one\\n'; echo two >&2; exit 3", 80, &|| false);
        assert!(preview.text.contains("one\n"));
        assert!(preview.text.contains("two\n"));
        assert_eq!(preview.status, Some(3));
        assert!(!preview.cut && !preview.timed_out);
    }

    #[test]
    fn a_preview_is_given_the_width_and_no_terminal() {
        let preview = run("echo $COLUMNS $PICKPEN_PREVIEW; tty", 61, &|| false);
        assert!(preview.text.starts_with("61 1\n"), "{}", preview.text);
        assert!(preview.text.contains("not a tty"), "{}", preview.text);
    }

    #[test]
    fn a_preview_the_view_gave_up_is_killed() {
        let started = Instant::now();
        let preview = run("sleep 5", 80, &|| {
            started.elapsed() > Duration::from_millis(100)
        });
        assert!(started.elapsed() < Duration::from_secs(3));
        assert_eq!(preview.status, None);
    }

    #[test]
    fn a_long_preview_is_cut() {
        let preview = run("head -c 400000 /dev/zero | tr '\\0' a", 80, &|| false);
        assert!(preview.cut);
        assert_eq!(preview.text.len(), MAX_OUTPUT);
    }
}
