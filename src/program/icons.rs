//! pickpen's icon, the mark its view shows, for a dark ground and a light one, 32 and 64 pixels a
//! side: a terminal draws it beside the program's name above the view. A terminal draws an icon only
//! from the bytes it is given (a `data:` URI), and never fetches one.

use pencere::{Icon, IconTheme};

const ICONS: [(&[u8], &str, IconTheme); 4] = [
    (include_bytes!("../assets/icon-32-dark.png"), "32x32", IconTheme::Dark),
    (include_bytes!("../assets/icon-64-dark.png"), "64x64", IconTheme::Dark),
    (include_bytes!("../assets/icon-32-light.png"), "32x32", IconTheme::Light),
    (include_bytes!("../assets/icon-64-light.png"), "64x64", IconTheme::Light),
];

pub fn icons() -> Vec<Icon> {
    ICONS
        .iter()
        .map(|(png, size, theme)| {
            let mut icon = Icon::new(format!("data:image/png;base64,{}", base64(png)));
            icon.mime_type = Some("image/png".to_owned());
            icon.sizes = vec![(*size).to_owned()];
            icon.theme = Some(*theme);
            icon
        })
        .collect()
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], chunk.get(1).copied().unwrap_or(0), chunk.get(2).copied().unwrap_or(0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for (i, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            if i <= chunk.len() {
                out.push(char::from(ALPHABET[((n >> shift) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn base64_is_the_standard_one() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foo"), "Zm9v");
        assert_eq!(super::base64(b"foobar"), "Zm9vYmFy");
    }
}
