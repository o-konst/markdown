//! Heading extraction and anchor slugs.
//!
//! The slug rules deliberately mirror `vue-project/src/composables/useDocumentOutline.ts`,
//! because both sides generate anchors for the same document: the preview builds them in the
//! browser, and this builds them for the MCP `outline` tool. If they disagreed, a link an
//! agent handed you would scroll to nothing.
//!
//! Headings inside fenced code blocks are not headings — a Rust doc comment beginning `# `
//! is a common way to get a bogus outline.

use serde::Serialize;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Heading {
    /// 1 for `#`, 6 for `######`.
    pub level: u8,
    pub text: String,
    /// Anchor slug, unique within the document.
    pub id: String,
    /// 1-based, so it can be reported next to search hits.
    pub line: usize,
}

/// Turns heading text into a URL fragment.
///
/// Mirrors the TypeScript: lowercase, NFKD, runs of non-alphanumerics collapse to `-`, and
/// leading and trailing `-` are trimmed. NFKD is what makes `café` become `cafe` — it splits
/// the accent into a combining mark, which is then dropped as a non-alphanumeric.
pub fn slugify(text: &str) -> String {
    let mut slug = String::with_capacity(text.len());
    let mut pending_dash = false;

    for ch in text.to_lowercase().nfkd() {
        if ch.is_alphanumeric() {
            if pending_dash && !slug.is_empty() {
                slug.push('-');
            }
            pending_dash = false;
            slug.push(ch);
        } else {
            pending_dash = true;
        }
    }
    slug
}

/// Reads the headings out of a Markdown document, assigning each a unique anchor.
pub fn outline(markdown: &str) -> Vec<Heading> {
    let mut headings: Vec<Heading> = Vec::new();
    let mut taken: Vec<String> = Vec::new();
    let mut fence: Option<char> = None;

    for (index, raw) in markdown.lines().enumerate() {
        let line = raw.trim_end();
        let trimmed = line.trim_start();

        // Fenced code: everything inside is content, not structure.
        if let Some(marker) = fence {
            if is_fence(trimmed, Some(marker)) {
                fence = None;
            }
            continue;
        }
        if is_fence(trimmed, None) {
            fence = trimmed.chars().next();
            continue;
        }

        let Some((level, text)) = parse_atx_heading(trimmed) else {
            continue;
        };

        // `ENABLE_HEADING_ATTRIBUTES` lets an author pin an anchor with `{#custom-id}`.
        let (text, explicit_id) = split_heading_attributes(&text);
        let base = explicit_id
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| slugify(&text));
        let base = if base.is_empty() {
            format!("section-{}", headings.len() + 1)
        } else {
            base
        };

        let mut id = base.clone();
        let mut suffix = 2;
        while taken.contains(&id) {
            id = format!("{base}-{suffix}");
            suffix += 1;
        }
        taken.push(id.clone());

        headings.push(Heading {
            level,
            text,
            id,
            line: index + 1,
        });
    }

    headings
}

fn is_fence(line: &str, expected: Option<char>) -> bool {
    let marker = match expected {
        Some(marker) => marker,
        None => match line.chars().next() {
            Some(ch @ ('`' | '~')) => ch,
            _ => return false,
        },
    };
    line.starts_with(&marker.to_string().repeat(3))
}

/// `## Title` becomes `(2, "Title")`. Anything else is not an ATX heading.
fn parse_atx_heading(line: &str) -> Option<(u8, String)> {
    let hashes = line.chars().take_while(|&c| c == '#').count();
    if hashes == 0 || hashes > 6 {
        return None;
    }
    let rest = &line[hashes..];
    // `#hashtag` is a tag, not a heading: a space is required.
    if !rest.is_empty() && !rest.starts_with(' ') && !rest.starts_with('\t') {
        return None;
    }
    // Closing hashes (`## Title ##`) are decoration.
    let text = rest.trim().trim_end_matches('#').trim().to_owned();
    Some((hashes as u8, text))
}

/// Splits `Title {#custom-id}` into its text and the pinned anchor.
fn split_heading_attributes(text: &str) -> (String, Option<String>) {
    let Some(open) = text.rfind("{#") else {
        return (text.to_owned(), None);
    };
    if !text.trim_end().ends_with('}') {
        return (text.to_owned(), None);
    }
    let close = text.rfind('}').unwrap_or(text.len());
    let id = text[open + 2..close].trim().to_owned();
    (text[..open].trim().to_owned(), Some(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Expected values captured by running the TypeScript rule in `useDocumentOutline.ts`
    /// directly, rather than reasoning about what it ought to produce.
    #[test]
    fn slugs_match_the_typescript_rules() {
        for (input, expected) in [
            ("Getting Started", "getting-started"),
            ("Deep detail", "deep-detail"),
            ("  Spaced  Out  ", "spaced-out"),
            ("Punctuation! Everywhere?", "punctuation-everywhere"),
            ("Hyphen-ated", "hyphen-ated"),
            ("under_score", "under-score"),
            // NFKD splits the accent off; a *trailing* mark is trimmed away...
            ("café", "cafe"),
            // ...but one mid-word leaves a separator behind. Faithful to the browser,
            // which is what makes an anchor an agent hands you actually resolve.
            ("Über", "u-ber"),
            ("naïve café", "nai-ve-cafe"),
            ("Ünicode Ärger", "u-nicode-a-rger"),
            // CJK is alphanumeric, so it survives intact.
            ("日本語", "日本語"),
            // Nothing alphanumeric at all: callers fall back to `section-N`.
            ("🎉", ""),
        ] {
            assert_eq!(slugify(input), expected, "input {input:?}");
        }
    }

    #[test]
    fn a_heading_with_no_slug_falls_back_to_its_position() {
        let headings = outline("# 🎉\n");
        assert_eq!(headings[0].id, "section-1");
    }

    #[test]
    fn duplicate_headings_get_numbered_anchors() {
        let headings = outline("## Overview\n\n## Overview\n\n## Overview\n");
        let ids: Vec<_> = headings.iter().map(|h| h.id.as_str()).collect();
        assert_eq!(ids, vec!["overview", "overview-2", "overview-3"]);
    }

    #[test]
    fn honours_an_author_supplied_anchor() {
        let headings = outline("## Custom Anchor {#my-anchor}\n");
        assert_eq!(headings[0].id, "my-anchor");
        assert_eq!(headings[0].text, "Custom Anchor");
    }

    #[test]
    fn records_levels_and_line_numbers() {
        let headings = outline("# One\n\ntext\n\n### Three\n");
        assert_eq!(headings[0].level, 1);
        assert_eq!(headings[0].line, 1);
        assert_eq!(headings[1].level, 3);
        assert_eq!(headings[1].line, 5);
    }

    #[test]
    fn ignores_headings_inside_fenced_code() {
        let headings = outline("# Real\n\n```rust\n# Not a heading\n```\n\n## Also real\n");
        let texts: Vec<_> = headings.iter().map(|h| h.text.as_str()).collect();
        assert_eq!(texts, vec!["Real", "Also real"]);
    }

    #[test]
    fn ignores_tilde_fences_too() {
        let headings = outline("~~~\n# hidden\n~~~\n\n# visible\n");
        assert_eq!(headings.len(), 1);
        assert_eq!(headings[0].text, "visible");
    }

    #[test]
    fn a_hashtag_is_not_a_heading() {
        assert!(outline("#tag not a heading\n").is_empty());
    }

    #[test]
    fn strips_closing_hashes() {
        let headings = outline("## Title ##\n");
        assert_eq!(headings[0].text, "Title");
    }

    #[test]
    fn seven_hashes_is_not_a_heading() {
        assert!(outline("####### too deep\n").is_empty());
    }

    /// The exact document used to verify the preview's outline earlier in this project.
    #[test]
    fn matches_the_previews_outline_for_the_reference_document() {
        let headings = outline(
            "# Getting Started\n\n## Overview\n\n### Deep detail\n\n#### Deeper still\n\n\
             ##### Five\n\n###### Six\n\n## Overview\n\n## Custom Anchor {#my-anchor}\n\n\
             # 🎉\n\n### Skipped level under h1\n",
        );
        let ids: Vec<_> = headings.iter().map(|h| h.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "getting-started",
                "overview",
                "deep-detail",
                "deeper-still",
                "five",
                "six",
                "overview-2",
                "my-anchor",
                "section-9",
                "skipped-level-under-h1",
            ]
        );
    }
}
