//! The command line that does again, with no person, what the person did in the view: the query
//! as `--where`, the order as `--sort`, and the output as it was shaped. Run in a script or by
//! cron, it writes the rows the query matches, which are the rows the person sent when they sent
//! every row the query showed.

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Recipe {
    /// `--input` as the person gave it; the shape read from the input needs no flag.
    pub input: Option<String>,
    /// `--delimiter` and `--read0`, as given.
    pub delimiter: Option<String>,
    pub read0: bool,
    pub where_: String,
    /// The column and whether the order is the other way.
    pub sort: Option<(String, bool)>,
    pub field: Option<Vec<String>>,
    pub format: Option<String>,
    pub output: Option<String>,
    pub print0: bool,
}

/// A word as a POSIX shell reads it back: bare when it is safe, in single quotes otherwise.
pub fn shell_quote(word: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c);
    if !word.is_empty() && word.chars().all(safe) {
        return word.to_string();
    }
    format!("'{}'", word.replace('\'', "'\\''"))
}

pub fn command_line(recipe: &Recipe) -> String {
    let given = |v: &Option<String>| v.as_deref().filter(|s| !s.is_empty()).map(str::to_string);
    let mut words = vec!["pickpen".to_string()];
    if let Some(input) = given(&recipe.input) {
        words.push("--input".to_string());
        words.push(input);
    }
    if let Some(delimiter) = given(&recipe.delimiter) {
        words.push("--delimiter".to_string());
        words.push(shell_quote(&delimiter));
    }
    if recipe.read0 {
        words.push("--read0".to_string());
    }
    words.push("--where".to_string());
    words.push(shell_quote(crate::values::js_trim(&recipe.where_)));
    if let Some((column, descending)) = &recipe.sort {
        words.push("--sort".to_string());
        words.push(shell_quote(&format!(
            "{}{column}",
            if *descending { "-" } else { "" }
        )));
    }
    if let Some(field) = recipe.field.as_ref().filter(|f| !f.is_empty()) {
        words.push("--field".to_string());
        words.push(shell_quote(&field.join(",")));
    } else if let Some(format) = given(&recipe.format) {
        words.push("--format".to_string());
        words.push(shell_quote(&format));
    } else if let Some(output) = given(&recipe.output) {
        words.push("--output".to_string());
        words.push(output);
    }
    if recipe.print0 {
        words.push("--print0".to_string());
    }
    words.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    // From test/output.test.ts.
    #[test]
    fn the_command_line_quotes_what_the_shell_would_split() {
        assert_eq!(shell_quote("NAME"), "NAME");
        assert_eq!(shell_quote("STATUS!=Running"), "'STATUS!=Running'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(
            command_line(&Recipe {
                where_: "STATUS!=Running cpu>50".to_string(),
                sort: Some(("%CPU".to_string(), true)),
                field: Some(vec!["NAME".to_string(), "PID".to_string()]),
                ..Recipe::default()
            }),
            "pickpen --where 'STATUS!=Running cpu>50' --sort -%CPU --field NAME,PID"
        );
        assert_eq!(
            command_line(&Recipe {
                input: Some("lines".to_string()),
                where_: String::new(),
                output: Some("json".to_string()),
                ..Recipe::default()
            }),
            "pickpen --input lines --where '' --output json"
        );
        assert_eq!(
            command_line(&Recipe {
                delimiter: Some(":".to_string()),
                read0: true,
                where_: "2>10".to_string(),
                field: Some(vec!["1".to_string()]),
                print0: true,
                ..Recipe::default()
            }),
            "pickpen --delimiter : --read0 --where '2>10' --field 1 --print0"
        );
    }
}
