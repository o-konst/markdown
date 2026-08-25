//! Lexical search across the vault, by file name and by content.
//!
//! This is the retrieval layer. There is no embedding index and nothing to keep fresh: a
//! query reads the notes it needs and returns snippets anchored to the heading they sit
//! under, so a caller can cite `note.md#some-heading` and have the link actually resolve.
//!
//! The caps mirror the ones already tuned in the macOS `FolderSearch.swift`, which this
//! replaces.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::outline::{outline, Heading};
use crate::store::is_markdown;

/// Files larger than this are matched on name only — one enormous file should not stall a
/// search over thousands of small ones.
const MAX_FILE_BYTES: u64 = 4 << 20;

const MAX_SNIPPETS_PER_FILE: usize = 3;

/// Enough to fill any sidebar many times over; past this the query is too broad to be useful.
const MAX_HITS: usize = 200;

const SNIPPET_CHARS: usize = 160;

/// One matching line, with the section it belongs to.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Snippet {
    /// 1-based.
    pub line: usize,
    pub text: String,
    /// Text of the nearest heading above this line, when there is one.
    pub heading: Option<String>,
    /// Anchor for that heading, so callers can link straight to the section.
    pub heading_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SearchHit {
    /// Vault-relative.
    pub path: String,
    pub name: String,
    /// True when the file's *name* matched, which sorts it above content-only matches.
    pub name_matched: bool,
    pub snippets: Vec<Snippet>,
}

/// Finds notes whose name or contents contain `query`.
///
/// Returns an empty result for a blank query rather than every note in the vault.
pub fn search(root: &Path, query: &str) -> Vec<SearchHit> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return Vec::new();
    }

    let mut hits = Vec::new();
    for path in markdown_files(root) {
        if hits.len() >= MAX_HITS {
            break;
        }

        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let name_matched = name.to_lowercase().contains(&needle);

        let too_big = fs::metadata(&path).map(|m| m.len() > MAX_FILE_BYTES).unwrap_or(true);
        let snippets = if too_big {
            Vec::new()
        } else {
            match fs::read_to_string(&path) {
                Ok(contents) => snippets_in(&contents, &needle),
                // Not UTF-8, so not a note we can read; a name match still counts.
                Err(_) => Vec::new(),
            }
        };

        if name_matched || !snippets.is_empty() {
            hits.push(SearchHit {
                path: path
                    .strip_prefix(root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .replace('\\', "/"),
                name,
                name_matched,
                snippets,
            });
        }
    }

    // Name matches first, then alphabetical, so results do not reshuffle between queries.
    hits.sort_by(|a, b| {
        b.name_matched
            .cmp(&a.name_matched)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    hits
}

/// Matching lines from one document, each tagged with the heading above it.
fn snippets_in(contents: &str, needle: &str) -> Vec<Snippet> {
    let headings = outline(contents);
    let mut snippets = Vec::new();

    for (index, line) in contents.lines().enumerate() {
        if snippets.len() >= MAX_SNIPPETS_PER_FILE {
            break;
        }
        if !line.to_lowercase().contains(needle) {
            continue;
        }

        let line_number = index + 1;
        let heading = enclosing_heading(&headings, line_number);
        snippets.push(Snippet {
            line: line_number,
            text: truncate(line.trim()),
            heading: heading.map(|h| h.text.clone()),
            heading_id: heading.map(|h| h.id.clone()),
        });
    }
    snippets
}

/// The last heading at or above `line`.
fn enclosing_heading(headings: &[Heading], line: usize) -> Option<&Heading> {
    headings.iter().take_while(|h| h.line <= line).last()
}

fn truncate(text: &str) -> String {
    if text.chars().count() <= SNIPPET_CHARS {
        return text.to_owned();
    }
    let mut out: String = text.chars().take(SNIPPET_CHARS).collect();
    out.push('…');
    out
}

/// Every Markdown file under `root`, skipping hidden folders — `.git` above all.
fn markdown_files(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];

    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
            } else if is_markdown(&path) {
                found.push(path);
            }
        }
    }

    // `read_dir` order is arbitrary; sort so results are reproducible.
    found.sort();
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn vault() -> TempDir {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(dir.path().join("notes")).unwrap();
        fs::create_dir_all(dir.path().join(".git")).unwrap();

        fs::write(
            dir.path().join("install-guide.md"),
            "# Install guide\n\nRun the installer.\n\n## Later\n\nSecond install mention.\n",
        )
        .unwrap();
        fs::write(
            dir.path().join("notes/other.md"),
            "# Other notes\n\nYou can install it later.\n",
        )
        .unwrap();
        fs::write(dir.path().join("notes/unrelated.md"), "# Unrelated\n\nNothing.\n").unwrap();
        fs::write(dir.path().join("ignored.png"), "install install install").unwrap();
        fs::write(dir.path().join(".git/config"), "install").unwrap();
        dir
    }

    #[test]
    fn finds_name_and_content_matches() {
        let dir = vault();
        let hits = search(dir.path(), "install");

        let paths: Vec<_> = hits.iter().map(|h| h.path.as_str()).collect();
        assert_eq!(paths, vec!["install-guide.md", "notes/other.md"]);
    }

    #[test]
    fn name_matches_sort_first() {
        let dir = vault();
        let hits = search(dir.path(), "install");
        assert!(hits[0].name_matched);
        assert!(!hits[1].name_matched);
    }

    #[test]
    fn skips_non_markdown_and_hidden_folders() {
        let dir = vault();
        let hits = search(dir.path(), "install");
        assert!(
            !hits.iter().any(|h| h.path.contains("ignored.png") || h.path.contains(".git")),
            "{hits:?}"
        );
    }

    #[test]
    fn snippets_carry_their_enclosing_heading() {
        let dir = vault();
        let hits = search(dir.path(), "install");
        let guide = &hits[0];

        // "# Install guide" itself, then the line under it, then the one under "## Later".
        let sections: Vec<_> = guide
            .snippets
            .iter()
            .map(|s| (s.heading.as_deref(), s.heading_id.as_deref()))
            .collect();
        assert_eq!(
            sections,
            vec![
                (Some("Install guide"), Some("install-guide")),
                (Some("Install guide"), Some("install-guide")),
                (Some("Later"), Some("later")),
            ]
        );
    }

    #[test]
    fn snippets_report_line_numbers() {
        let dir = vault();
        let hits = search(dir.path(), "installer");
        assert_eq!(hits[0].snippets[0].line, 3);
        assert_eq!(hits[0].snippets[0].text, "Run the installer.");
    }

    #[test]
    fn search_is_case_insensitive() {
        let dir = vault();
        assert_eq!(search(dir.path(), "INSTALL").len(), search(dir.path(), "install").len());
    }

    #[test]
    fn a_blank_query_matches_nothing() {
        let dir = vault();
        assert!(search(dir.path(), "").is_empty());
        assert!(search(dir.path(), "   ").is_empty());
    }

    #[test]
    fn caps_snippets_per_file() {
        let dir = TempDir::new().unwrap();
        let body = "needle\n".repeat(50);
        fs::write(dir.path().join("many.md"), body).unwrap();

        let hits = search(dir.path(), "needle");
        assert_eq!(hits[0].snippets.len(), MAX_SNIPPETS_PER_FILE);
    }

    #[test]
    fn long_lines_are_truncated() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("long.md"), format!("needle {}", "x".repeat(500))).unwrap();

        let text = &search(dir.path(), "needle")[0].snippets[0].text;
        assert!(text.chars().count() <= SNIPPET_CHARS + 1, "{}", text.len());
        assert!(text.ends_with('…'));
    }

    #[test]
    fn a_huge_file_still_matches_on_name() {
        let dir = TempDir::new().unwrap();
        let big = "x".repeat((MAX_FILE_BYTES + 1) as usize);
        fs::write(dir.path().join("needle-in-name.md"), big).unwrap();

        let hits = search(dir.path(), "needle");
        assert_eq!(hits.len(), 1);
        assert!(hits[0].name_matched);
        assert!(hits[0].snippets.is_empty(), "huge file should not be read");
    }

    #[test]
    fn finds_notes_in_nested_folders() {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(dir.path().join("a/b/c")).unwrap();
        fs::write(dir.path().join("a/b/c/deep.md"), "needle here\n").unwrap();

        let hits = search(dir.path(), "needle");
        assert_eq!(hits[0].path, "a/b/c/deep.md");
    }
}
