//! What a cell says as a quantity: a number, a size, a length of time or a moment. The query's
//! comparisons and the sort read cells through this one function, in the view and in the
//! program alike, so that `cpu>50` and `--sort -cpu` mean the same rows wherever they run. A
//! cell is read on its own, never by the type of its column: a column whose every other cell
//! is a size does not make a stray word one.
//!
//! The text rules here are JavaScript's, which the first pickpen was written in and whose
//! behaviour this one keeps: what a space is (`js_space`, `js_trim`), how long a text is
//! (`utf16_len`), and how a number is written (`js_number`).

/// The kinds of quantity, in the order their names sort (`date`, `duration`, `number`, `size`),
/// which is the order the sort puts quantities of kinds that do not compare.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Kind {
    Date,
    Duration,
    Number,
    Size,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Date => "date",
            Kind::Duration => "duration",
            Kind::Number => "number",
            Kind::Size => "size",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quantity {
    pub kind: Kind,
    /// In the kind's base unit: bytes, seconds, milliseconds since 1970.
    pub value: f64,
}

/// A space as JavaScript's `\s` and `trim` have it: Unicode's spaces and line ends, and the
/// byte order mark, but not U+0085, which Rust's `char::is_whitespace` counts.
pub fn js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202F}'
                | '\u{205F}'
                | '\u{3000}'
                | '\u{FEFF}'
    )
}

/// The text without the spaces at its ends, as JavaScript's `trim` does.
pub fn js_trim(text: &str) -> &str {
    text.trim_matches(js_space)
}

/// How long a text is in UTF-16 code units, which is what a JavaScript string's `length` counts.
pub fn utf16_len(text: &str) -> usize {
    if text.is_ascii() {
        return text.len();
    }
    text.chars().map(char::len_utf16).sum()
}

/// A number as JavaScript's `String(n)` writes it: the shortest digits that read back as the
/// same number, `1e+21` from twenty-one digits on and `1e-7` below a millionth, and `-0` as `0`.
pub fn js_number(n: f64) -> String {
    if n.is_nan() {
        return "NaN".to_string();
    }
    if n.is_infinite() {
        return if n > 0.0 { "Infinity" } else { "-Infinity" }.to_string();
    }
    if n == 0.0 {
        return "0".to_string();
    }
    let (digits, n10) = shortest_digits(n.abs());
    let mut out = String::new();
    if n < 0.0 {
        out.push('-');
    }
    let k = digits.len() as i32;
    if k <= n10 && n10 <= 21 {
        out.push_str(&digits);
        out.extend(std::iter::repeat_n('0', (n10 - k) as usize));
    } else if 0 < n10 && n10 <= 21 {
        out.push_str(&digits[..n10 as usize]);
        out.push('.');
        out.push_str(&digits[n10 as usize..]);
    } else if -6 < n10 && n10 <= 0 {
        out.push_str("0.");
        out.extend(std::iter::repeat_n('0', (-n10) as usize));
        out.push_str(&digits);
    } else {
        out.push_str(&digits[..1]);
        if k > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        let e = n10 - 1;
        out.push('e');
        out.push(if e < 0 { '-' } else { '+' });
        out.push_str(&e.abs().to_string());
    }
    out
}

/// The shortest digits of a positive number, and where the point goes: `0.0123` is `("123", -1)`,
/// read as 0.123 × 10⁻¹. Rust's `{:e}` finds how few digits read back as the number; of the
/// numbers with that many, JavaScript writes the nearest (a tie to the even one), which is what
/// rounding the exact value to that many digits gives.
fn shortest_digits(n: f64) -> (String, i32) {
    let split = |written: &str| {
        let (mantissa, exponent) = written.split_once('e').unwrap_or((written, "0"));
        let digits: String = mantissa.chars().filter(|c| c.is_ascii_digit()).collect();
        (digits, exponent.parse::<i32>().unwrap_or(0) + 1)
    };
    let shortest = split(&format!("{n:e}"));
    let nearest = split(&format!("{:.*e}", shortest.0.len().saturating_sub(1), n));
    let point = nearest.1 - nearest.0.len() as i32;
    let reads_back = format!("{}e{point}", nearest.0).parse() == Ok(n);
    if nearest.0.len() == shortest.0.len() && reads_back {
        nearest
    } else {
        shortest
    }
}

/// JavaScript's `n.toPrecision(p)` read back as a number: the number to `p` significant digits,
/// a tie rounded away from zero, as the exact value of the number says.
fn to_precision(n: f64, p: usize) -> f64 {
    if !n.is_finite() || n == 0.0 {
        return n;
    }
    // Every finite number has an exact decimal expansion of fewer than 800 digits.
    let exact = format!("{:.800e}", n.abs());
    let (mantissa, exponent) = exact.split_once('e').unwrap_or((&exact, "0"));
    let mut exponent: i32 = exponent.parse().unwrap_or(0);
    let all: Vec<u8> = mantissa.bytes().filter(u8::is_ascii_digit).collect();
    let mut kept: Vec<u8> = all.iter().take(p).copied().collect();
    if all.get(p).is_some_and(|d| *d >= b'5') {
        let mut at = kept.len();
        loop {
            if at == 0 {
                kept.insert(0, b'1');
                kept.pop();
                exponent += 1;
                break;
            }
            at -= 1;
            if kept[at] == b'9' {
                kept[at] = b'0';
            } else {
                kept[at] += 1;
                break;
            }
        }
    }
    let text = format!(
        "{}{}e{}",
        if n < 0.0 { "-" } else { "" },
        String::from_utf8_lossy(&kept),
        exponent - (p as i32 - 1)
    );
    text.parse().unwrap_or(n)
}

const SECONDS: [(&str, f64); 7] = [
    ("ms", 0.001),
    ("s", 1.0),
    ("m", 60.0),
    ("h", 3600.0),
    ("d", 86_400.0),
    ("w", 604_800.0),
    ("y", 31_536_000.0),
];

/// How many bytes of `text`, from `at`, are ASCII digits.
fn digits_at(text: &[u8], at: usize) -> usize {
    text.get(at..).map_or(0, |rest| {
        rest.iter().take_while(|b| b.is_ascii_digit()).count()
    })
}

/// The length of the decimal number `[+-]?(\d+\.?\d*|\.\d+)` at the start of `text`, if one is.
fn decimal_len(text: &[u8]) -> Option<usize> {
    let mut at = usize::from(matches!(text.first(), Some(b'+' | b'-')));
    let whole = digits_at(text, at);
    at += whole;
    if whole > 0 {
        if text.get(at) == Some(&b'.') {
            at += 1;
            at += digits_at(text, at);
        }
        return Some(at);
    }
    if text.get(at) != Some(&b'.') {
        return None;
    }
    let fraction = digits_at(text, at + 1);
    if fraction == 0 {
        return None;
    }
    Some(at + 1 + fraction)
}

/// A number written as JavaScript's `Number` reads the forms these patterns allow.
fn number(text: &str) -> f64 {
    text.parse().unwrap_or(f64::NAN)
}

/// The quantity a cell holds, or `None` when it holds words.
///
/// - `12`, `-3.5`, `1e6`, `12%` are numbers (a percentage is its number);
/// - `1.2G`, `512Ki`, `3.4 MB`, `200M`, `10k` are sizes: one letter and `iB` count in 1024s,
///   as `ls -h`, `du -h` and Kubernetes do, and `kB`, `MB` and the rest in 1000s, as Docker does;
/// - `45s`, `3m`, `5d2h`, `500ms`, `1:02:03`, `0:01.23` are lengths of time: a small `m` is
///   minutes and a capital `M` a size;
/// - `2026-10-22`, `2026-10-22T10:00:00Z`, `2026-10-22 10:00` are moments.
pub fn quantity(cell: &str) -> Option<Quantity> {
    let text = js_trim(cell);
    if text.is_empty() || utf16_len(text) > 40 {
        return None;
    }
    let bytes = text.as_bytes();
    if let Some(len) = decimal_len(bytes) {
        let (decimal, rest) = text.split_at(len);
        if is_exponent(rest.as_bytes()) {
            return Some(Quantity {
                kind: Kind::Number,
                value: number(text),
            });
        }
        // An optional space, then `%` or a unit.
        let after = match rest.chars().next() {
            Some(c) if js_space(c) => &rest[c.len_utf8()..],
            _ => rest,
        };
        if after == "%" {
            return Some(Quantity {
                kind: Kind::Number,
                value: number(decimal),
            });
        }
        if let Some(value) = size(decimal, after) {
            return Some(Quantity {
                kind: Kind::Size,
                value,
            });
        }
    }
    if let Some(seconds) = duration(bytes) {
        return Some(Quantity {
            kind: Kind::Duration,
            value: seconds,
        });
    }
    if let Some(seconds) = clock(text) {
        return Some(Quantity {
            kind: Kind::Duration,
            value: seconds,
        });
    }
    if let Some(value) = date(text) {
        return Some(Quantity {
            kind: Kind::Date,
            value,
        });
    }
    None
}

/// Whether `text` is nothing, or an exponent `[eE][+-]?\d+`, which is all a number may end with.
fn is_exponent(text: &[u8]) -> bool {
    if text.is_empty() {
        return true;
    }
    if !matches!(text[0], b'e' | b'E') {
        return false;
    }
    let at = 1 + usize::from(matches!(text.get(1), Some(b'+' | b'-')));
    let digits = digits_at(text, at);
    digits > 0 && at + digits == text.len()
}

/// A size's bytes: the unit is `[kKmMgGtTpP]i?[bB]?` or `[bB]`.
fn size(decimal: &str, unit: &str) -> Option<f64> {
    let u = unit.as_bytes();
    let letter = u.first()?.to_ascii_lowercase();
    // `b` alone is bytes; `m` alone (no `i`, no `b`) is minutes, read as a duration.
    if letter == b'b' {
        return (u.len() == 1).then(|| number(decimal));
    }
    let power = match letter {
        b'k' => 1,
        b'm' => 2,
        b'g' => 3,
        b't' => 4,
        b'p' => 5,
        _ => return None,
    };
    let mut at = 1;
    let binary_i = u.get(at) == Some(&b'i');
    if binary_i {
        at += 1;
    }
    if matches!(u.get(at), Some(b'b' | b'B')) {
        at += 1;
    }
    if at != u.len() || unit == "m" {
        return None;
    }
    let binary = u.len() == 1 || binary_i;
    let base: f64 = if binary { 1024.0 } else { 1000.0 };
    Some(number(decimal) * base.powi(power))
}

/// `(\d+(\.\d+)?(ms|y|w|d|h|m|s))+`, in seconds.
fn duration(text: &[u8]) -> Option<f64> {
    let mut seconds = 0.0;
    let mut at = 0;
    while at < text.len() {
        let from = at;
        let whole = digits_at(text, at);
        if whole == 0 {
            return None;
        }
        at += whole;
        if text.get(at) == Some(&b'.') {
            let fraction = digits_at(text, at + 1);
            if fraction > 0 {
                at += 1 + fraction;
            }
        }
        let amount = number(std::str::from_utf8(&text[from..at]).ok()?);
        let unit = if text[at..].starts_with(b"ms") {
            "ms"
        } else {
            match text.get(at) {
                Some(b'y') => "y",
                Some(b'w') => "w",
                Some(b'd') => "d",
                Some(b'h') => "h",
                Some(b'm') => "m",
                Some(b's') => "s",
                _ => return None,
            }
        };
        at += unit.len();
        let size = SECONDS
            .iter()
            .find(|(u, _)| *u == unit)
            .map_or(1.0, |(_, s)| *s);
        seconds += amount * size;
    }
    Some(seconds)
}

/// `(\d+):(\d{2})(:(\d{2}))?(\.\d+)?`, in seconds.
fn clock(text: &str) -> Option<f64> {
    let b = text.as_bytes();
    let a = digits_at(b, 0);
    if a == 0 || b.get(a) != Some(&b':') || digits_at(b, a + 1) < 2 {
        return None;
    }
    let mut at = a + 3;
    let first = number(&text[..a]);
    let second = number(&text[a + 1..a + 3]);
    let mut third = None;
    if b.get(at) == Some(&b':') && digits_at(b, at + 1) >= 2 {
        third = Some(number(&text[at + 1..at + 3]));
        at += 3;
    }
    let mut fraction = 0.0;
    if b.get(at) == Some(&b'.') {
        let n = digits_at(b, at + 1);
        if n == 0 {
            return None;
        }
        fraction = number(&text[at..at + 1 + n]);
        at += 1 + n;
    }
    if at != b.len() {
        return None;
    }
    let seconds = match third {
        None => first * 60.0 + second,
        Some(third) => first * 3600.0 + second * 60.0 + third,
    };
    Some(seconds + fraction)
}

/// The number the digits at `at..at + n` are, when there are that many there.
fn fixed(b: &[u8], at: usize, n: usize) -> Option<i64> {
    if digits_at(b, at) < n {
        return None;
    }
    let mut value = 0i64;
    for d in &b[at..at + n] {
        value = value * 10 + i64::from(d - b'0');
    }
    Some(value)
}

/// A moment, `\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?`, in
/// milliseconds since 1970 as JavaScript's `Date.parse` reads it: a day alone is in UTC, a time
/// without a zone in the local one; a day past its month's end runs on into the next, and a
/// month, hour or minute out of range is no moment.
fn date(text: &str) -> Option<f64> {
    let b = text.as_bytes();
    let year = fixed(b, 0, 4)?;
    if b.get(4) != Some(&b'-') || b.get(7) != Some(&b'-') {
        return None;
    }
    let month = fixed(b, 5, 2)?;
    let day = fixed(b, 8, 2)?;
    let mut at = 10;
    let mut time = None;
    let mut offset = None;
    if at < b.len() {
        if !matches!(b[at], b'T' | b' ') {
            return None;
        }
        let hour = fixed(b, at + 1, 2)?;
        if b.get(at + 3) != Some(&b':') {
            return None;
        }
        let minute = fixed(b, at + 4, 2)?;
        at += 6;
        let mut second = 0;
        let mut millis = 0;
        if b.get(at) == Some(&b':') {
            second = fixed(b, at + 1, 2)?;
            at += 3;
            if b.get(at) == Some(&b'.') {
                let n = digits_at(b, at + 1);
                if n == 0 {
                    return None;
                }
                // Past the milliseconds, digits are dropped, not rounded.
                for k in 0..3 {
                    let d = b.get(at + 1 + k).filter(|_| k < n).map_or(0, |d| d - b'0');
                    millis = millis * 10 + i64::from(d);
                }
                at += 1 + n;
            }
        }
        if at < b.len() {
            if b[at] == b'Z' && at + 1 == b.len() {
                offset = Some(0);
                at += 1;
            } else if matches!(b[at], b'+' | b'-') {
                let sign = if b[at] == b'-' { -1 } else { 1 };
                let hours = fixed(b, at + 1, 2)?;
                at += 3;
                if b.get(at) == Some(&b':') {
                    at += 1;
                }
                let minutes = fixed(b, at, 2)?;
                at += 2;
                if hours > 23 || minutes > 59 {
                    return None;
                }
                offset = Some(sign * (hours * 60 + minutes) * 60_000);
            } else {
                return None;
            }
            if at != b.len() {
                return None;
            }
        }
        if hour > 24 || minute > 59 || second > 59 {
            return None;
        }
        if hour == 24 && (minute != 0 || second != 0 || millis != 0) {
            return None;
        }
        time = Some(((hour * 60 + minute) * 60 + second) * 1000 + millis);
    }
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let days = days_from_civil(year, month) + day - 1;
    let moment = days * 86_400_000 + time.unwrap_or(0);
    let utc = match (time, offset) {
        (None, _) => moment,
        (Some(_), Some(offset)) => moment - offset,
        (Some(_), None) => moment - local_offset(moment),
    };
    Some(utc as f64)
}

/// Days from 1970-01-01 to the first of a month of the proleptic Gregorian calendar.
fn days_from_civil(year: i64, month: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// How far the local zone is ahead of UTC, in milliseconds, for a local time written as if it
/// were UTC. Where the clocks went forward, the time is read with the offset before; where they
/// went back, the earlier of the two moments is taken: as JavaScript does.
fn local_offset(local: i64) -> i64 {
    let early = offset_at(local - 86_400_000);
    let late = offset_at(local + 86_400_000);
    let fits = |offset: i64| offset_at(local - offset) == offset;
    match (fits(early), fits(late)) {
        (true, true) => early.max(late),
        (true, false) => early,
        (false, true) => late,
        (false, false) => early,
    }
}

/// The local zone's offset from UTC at a moment, in milliseconds.
#[cfg(unix)]
fn offset_at(moment: i64) -> i64 {
    unsafe extern "C" {
        fn tzset();
    }
    static ZONE: std::sync::Once = std::sync::Once::new();
    // SAFETY: tzset reads TZ once, before any localtime_r of this program.
    ZONE.call_once(|| unsafe { tzset() });
    let seconds = moment.div_euclid(1000) as libc::time_t;
    // SAFETY: an all-zero `tm` is a valid value, and localtime_r only writes into it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are to live values of the right types.
    let done = unsafe { libc::localtime_r(&seconds, &mut tm) };
    if done.is_null() {
        return 0;
    }
    tm.tm_gmtoff * 1000
}

#[cfg(not(unix))]
fn offset_at(_moment: i64) -> i64 {
    0
}

/// Whether two quantities can be compared: of one kind, or one a bare number, which is read in
/// the other's base unit (`size>1000` is a thousand bytes). A moment is compared only with a
/// moment.
pub fn comparable(a: Quantity, b: Quantity) -> bool {
    if a.kind == b.kind {
        return true;
    }
    if a.kind == Kind::Date || b.kind == Kind::Date {
        return false;
    }
    a.kind == Kind::Number || b.kind == Kind::Number
}

/// The kind most of a column's cells have, or none for words: what the view aligns and charts
/// by. It reads the first 500 cells that are not blank.
pub fn column_kind<'a>(cells: impl IntoIterator<Item = &'a str>) -> Option<Kind> {
    column_kind_sampled(cells, 500)
}

/// `column_kind` from the first `sample` cells that are not blank.
pub fn column_kind_sampled<'a>(
    cells: impl IntoIterator<Item = &'a str>,
    sample: usize,
) -> Option<Kind> {
    // In the order the kinds were first seen, so that a tie goes to the first.
    let mut counts: Vec<(Kind, usize)> = Vec::new();
    let mut filled = 0;
    for cell in cells {
        if js_trim(cell).is_empty() {
            continue;
        }
        filled += 1;
        if let Some(q) = quantity(cell) {
            match counts.iter_mut().find(|(kind, _)| *kind == q.kind) {
                Some((_, count)) => *count += 1,
                None => counts.push((q.kind, 1)),
            }
        }
        if filled >= sample {
            break;
        }
    }
    if filled == 0 {
        return None;
    }
    let mut best = None;
    let mut most = 0;
    for (kind, count) in &counts {
        if *count > most {
            best = Some(*kind);
            most = *count;
        }
    }
    let best = best?;
    // Numbers read in any unit's column ("0" in a column of sizes), so they count for it.
    let numbers = if best == Kind::Number {
        0
    } else {
        counts
            .iter()
            .find(|(kind, _)| *kind == Kind::Number)
            .map_or(0, |(_, n)| *n)
    };
    if (most + numbers) as f64 / filled as f64 >= 0.8 {
        Some(best)
    } else {
        None
    }
}

/// A quantity as a person writes it in a query: what the column panel puts there.
pub fn write_quantity(kind: Kind, value: f64) -> String {
    let round = |n: f64| js_number(to_precision(n, 3));
    match kind {
        Kind::Number => round(value),
        Kind::Size => {
            let units = ["", "Ki", "Mi", "Gi", "Ti", "Pi"];
            let mut n = value;
            let mut at = 0;
            while n.abs() >= 1024.0 && at < units.len() - 1 {
                n /= 1024.0;
                at += 1;
            }
            if at == 0 {
                format!("{}B", round(n))
            } else {
                format!("{}{}", round(n), units[at])
            }
        }
        Kind::Duration => {
            let steps = [("d", 86_400.0), ("h", 3600.0), ("m", 60.0), ("s", 1.0)];
            for (unit, size) in steps {
                if value.abs() >= size {
                    return format!("{}{}", round(value / size), unit);
                }
            }
            format!("{}ms", js_number(js_round(value * 1000.0)))
        }
        Kind::Date => {
            let iso = iso_string(value);
            if iso == "Invalid Date" {
                return iso;
            }
            if iso.ends_with("T00:00:00.000Z") {
                iso[..10].to_string()
            } else {
                format!("{}Z", &iso[..19])
            }
        }
    }
}

/// JavaScript's `Math.round`: to the nearest whole number, a half up.
fn js_round(n: f64) -> f64 {
    if !n.is_finite() {
        return n;
    }
    let floor = n.floor();
    // -0.4 rounds to -0, which `js_number` writes as 0 either way.
    if n - floor >= 0.5 { floor + 1.0 } else { floor }
}

/// A moment as JavaScript's `toISOString` writes it: `2026-10-22T10:00:00.000Z`, with six digits
/// and a sign for a year before 0 or after 9999. JavaScript throws for a moment that is not one
/// (NaN, or too far off); this writes `Invalid Date`, as `String(date)` would.
pub fn iso_string(value: f64) -> String {
    if !value.is_finite() || value.abs() > 8.64e15 {
        return "Invalid Date".to_string();
    }
    let ms = value.trunc() as i64;
    let days = ms.div_euclid(86_400_000);
    let in_day = ms.rem_euclid(86_400_000);
    let (year, month, day) = civil_from_days(days);
    let year = if (0..=9999).contains(&year) {
        format!("{year:04}")
    } else if year < 0 {
        format!("-{:06}", -year)
    } else {
        format!("+{year:06}")
    };
    format!(
        "{year}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        in_day / 3_600_000,
        in_day / 60_000 % 60,
        in_day / 1000 % 60,
        in_day % 1000
    )
}

/// The year, month and day of a count of days from 1970-01-01.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
#[path = "values_tests.rs"]
mod tests;
