//! Reading and changing files in the vault.
//!
//! Every method that takes a path routes it through [`crate::confine::resolve_in`], and every
//! method that changes something commits through [`crate::history`]. Those two rules are what
//! let the layers above — the FFI, the MCP server, the agent — treat this as safe.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::confine::{resolve_in, ConfineError};
use crate::history::{History, HistoryError};

/// File kinds the vault surfaces. Everything else is invisible to every front end.
pub const MARKDOWN_EXTENSIONS: &[&str] = &["md", "markdown", "mdown", "mkd", "mdx", "text", "txt"];

pub fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| MARKDOWN_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

#[derive(Debug)]
pub enum VaultError {
    Path(ConfineError),
    History(HistoryError),
    Io(String),
    /// A create was asked for but something is already there.
    Exists(String),
    /// The path is the wrong kind — a folder where a file was wanted, or the reverse.
    WrongKind(String),
    /// The file is not valid UTF-8, so it is not a note we can edit.
    NotText(String),
    /// An edit's `old_text` is not present in the file.
    NoMatch(String),
    /// An edit's `old_text` appears more than once, so the intended target is unknown.
    AmbiguousMatch(usize),
}

impl std::fmt::Display for VaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Path(err) => write!(f, "{err}"),
            Self::History(err) => write!(f, "{err}"),
            Self::Io(why) => write!(f, "{why}"),
            Self::Exists(path) => write!(f, "already exists: {path}"),
            Self::WrongKind(path) => write!(f, "not the expected kind of path: {path}"),
            Self::NotText(path) => write!(f, "not a UTF-8 text file: {path}"),
            Self::NoMatch(path) => write!(f, "the text to replace was not found in {path}"),
            Self::AmbiguousMatch(count) => write!(
                f,
                "the text to replace appears {count} times; include enough surrounding text to \
                 identify one of them"
            ),
        }
    }
}

impl std::error::Error for VaultError {}

impl From<ConfineError> for VaultError {
    fn from(err: ConfineError) -> Self {
        Self::Path(err)
    }
}

impl From<HistoryError> for VaultError {
    fn from(err: HistoryError) -> Self {
        Self::History(err)
    }
}

impl From<std::io::Error> for VaultError {
    fn from(err: std::io::Error) -> Self {
        Self::Io(err.to_string())
    }
}

/// One entry in a folder listing.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ListEntry {
    /// Vault-relative, the only form any caller ever sees.
    pub path: String,
    pub name: String,
    pub is_directory: bool,
}

pub struct Vault {
    root: PathBuf,
    history: History,
}

impl Vault {
    pub fn open(root: &Path) -> Result<Self, VaultError> {
        let root = root
            .canonicalize()
            .map_err(|why| ConfineError::RootUnavailable(why.to_string()))?;
        let history = History::open_or_init(&root)?;

        // Baseline an adopted folder. Without a commit to return to, undoing the *first*
        // change would delete the file instead of restoring what was there before it.
        if history.log(1)?.is_empty() {
            history.commit_all("Baseline")?;
        }
        Ok(Self { root, history })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn history(&self) -> &History {
        &self.history
    }

    // MARK: - Reading

    pub fn read(&self, path: &str) -> Result<String, VaultError> {
        let resolved = resolve_in(&self.root, path, true)?;
        if resolved.is_dir() {
            return Err(VaultError::WrongKind(path.to_owned()));
        }
        fs::read_to_string(&resolved).map_err(|_| VaultError::NotText(path.to_owned()))
    }

    /// Immediate children of `dir` (the vault root when `None`), folders first.
    ///
    /// Only folders and Markdown files are listed, so a vault sitting alongside other work
    /// reads as a list of notes rather than a file browser.
    pub fn list(&self, dir: Option<&str>) -> Result<Vec<ListEntry>, VaultError> {
        let target = match dir {
            Some(dir) if !dir.trim().trim_matches('/').is_empty() => {
                resolve_in(&self.root, dir, true)?
            }
            _ => self.root.clone(),
        };
        if !target.is_dir() {
            return Err(VaultError::WrongKind(dir.unwrap_or("/").to_owned()));
        }

        let mut entries = Vec::new();
        for entry in fs::read_dir(&target)? {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();

            // `.git` is our own history; hidden files are not notes.
            if name.starts_with('.') {
                continue;
            }
            let is_directory = path.is_dir();
            if !is_directory && !is_markdown(&path) {
                continue;
            }

            entries.push(ListEntry {
                path: self.relative(&path),
                name,
                is_directory,
            });
        }

        entries.sort_by(|a, b| {
            b.is_directory
                .cmp(&a.is_directory)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(entries)
    }

    // MARK: - Changing

    /// Writes `contents`, creating the file or replacing what is there, then commits.
    pub fn write(&self, path: &str, contents: &str) -> Result<Option<String>, VaultError> {
        let resolved = resolve_in(&self.root, path, false)?;
        if resolved.is_dir() {
            return Err(VaultError::WrongKind(path.to_owned()));
        }
        fs::write(&resolved, contents)?;
        Ok(self.history.commit_all(&format!("Write {path}"))?)
    }

    /// Like [`Self::write`] but refuses to clobber an existing note.
    pub fn create_file(&self, path: &str, contents: &str) -> Result<Option<String>, VaultError> {
        let resolved = resolve_in(&self.root, path, false)?;
        if resolved.exists() {
            return Err(VaultError::Exists(path.to_owned()));
        }
        fs::write(&resolved, contents)?;
        Ok(self.history.commit_all(&format!("Create {path}"))?)
    }

    /// Replaces one exact occurrence of `old_text` with `new_text`.
    ///
    /// Refuses when the match is absent or ambiguous. A model that mis-remembers the text it
    /// is editing should get an error, not a silent edit in the wrong place — and replacing
    /// *all* occurrences would make an ambiguous request quietly destructive.
    pub fn edit(
        &self,
        path: &str,
        old_text: &str,
        new_text: &str,
    ) -> Result<Option<String>, VaultError> {
        if old_text.is_empty() {
            return Err(VaultError::NoMatch(path.to_owned()));
        }

        let contents = self.read(path)?;
        let occurrences = contents.matches(old_text).count();
        match occurrences {
            0 => return Err(VaultError::NoMatch(path.to_owned())),
            1 => {}
            n => return Err(VaultError::AmbiguousMatch(n)),
        }

        let updated = contents.replacen(old_text, new_text, 1);
        let resolved = resolve_in(&self.root, path, true)?;
        fs::write(&resolved, updated)?;
        Ok(self.history.commit_all(&format!("Edit {path}"))?)
    }

    /// Creates a folder, including any missing parents inside the vault.
    pub fn create_folder(&self, path: &str) -> Result<Option<String>, VaultError> {
        // Parents may not exist yet, so confine the topmost missing segment instead.
        let resolved = self.resolve_for_create(path)?;
        if resolved.exists() {
            return Err(VaultError::Exists(path.to_owned()));
        }
        fs::create_dir_all(&resolved)?;
        // Git does not track empty folders, so this is usually not a commit on its own.
        Ok(self.history.commit_all(&format!("Create folder {path}"))?)
    }

    pub fn move_path(&self, from: &str, to: &str) -> Result<Option<String>, VaultError> {
        let source = resolve_in(&self.root, from, true)?;
        let destination = self.resolve_for_create(to)?;
        if destination.exists() {
            return Err(VaultError::Exists(to.to_owned()));
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::rename(&source, &destination)?;
        Ok(self.history.commit_all(&format!("Move {from} to {to}"))?)
    }

    /// Removes a file or folder. Recoverable: the deletion is a commit like any other.
    pub fn delete(&self, path: &str) -> Result<Option<String>, VaultError> {
        let resolved = resolve_in(&self.root, path, true)?;
        if resolved == self.root {
            return Err(VaultError::WrongKind(path.to_owned()));
        }
        if resolved.is_dir() {
            fs::remove_dir_all(&resolved)?;
        } else {
            fs::remove_file(&resolved)?;
        }
        Ok(self.history.commit_all(&format!("Delete {path}"))?)
    }

    /// Undoes a change by its commit id.
    pub fn undo(&self, commit_id: &str) -> Result<String, VaultError> {
        Ok(self.history.revert(commit_id)?)
    }

    // MARK: - Helpers

    /// Confines a path whose *own* parents may not exist yet, by walking up to the deepest
    /// existing ancestor and confining that.
    fn resolve_for_create(&self, path: &str) -> Result<PathBuf, VaultError> {
        match resolve_in(&self.root, path, false) {
            Ok(resolved) => Ok(resolved),
            // `mkdir -p` semantics: confine the deepest existing ancestor, then re-attach
            // the missing tail, so a symlinked ancestor is still caught.
            Err(ConfineError::ParentMissing(_)) => {
                let relative = path.trim().trim_start_matches('/');
                let mut ancestor = Path::new(relative);
                let mut tail = Vec::new();
                loop {
                    let parent = ancestor
                        .parent()
                        .ok_or(ConfineError::ParentMissing(relative.to_owned()))?;
                    let name = ancestor
                        .file_name()
                        .ok_or(ConfineError::Empty)?
                        .to_owned();
                    tail.push(name);
                    if parent.as_os_str().is_empty() {
                        let mut resolved = self.root.clone();
                        for segment in tail.iter().rev() {
                            resolved.push(segment);
                        }
                        return Ok(resolved);
                    }
                    if self.root.join(parent).exists() {
                        let mut resolved = resolve_in(
                            &self.root,
                            parent.to_str().ok_or(ConfineError::Empty)?,
                            true,
                        )?;
                        for segment in tail.iter().rev() {
                            resolved.push(segment);
                        }
                        if !resolved.starts_with(&self.root) {
                            return Err(ConfineError::Escapes(relative.to_owned()).into());
                        }
                        return Ok(resolved);
                    }
                    ancestor = parent;
                }
            }
            Err(err) => Err(err.into()),
        }
    }

    fn relative(&self, path: &Path) -> String {
        // Vault paths are a logical, POSIX-style contract shared with the outline/search/tool
        // schemas, regardless of the host OS's native separator.
        path.strip_prefix(&self.root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn vault() -> (TempDir, Vault) {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(dir.path().join("notes")).unwrap();
        fs::write(dir.path().join("top.md"), "top\n").unwrap();
        fs::write(dir.path().join("notes/nested.md"), "nested\n").unwrap();
        fs::write(dir.path().join("ignored.png"), "binary").unwrap();
        let vault = Vault::open(dir.path()).unwrap();
        (dir, vault)
    }

    #[test]
    fn opening_baselines_an_adopted_folder() {
        let (_dir, vault) = vault();
        assert_eq!(vault.history().log(10).unwrap().len(), 1, "no baseline commit");
        assert!(!vault.history().is_dirty().unwrap());
    }

    #[test]
    fn the_first_change_is_undoable_back_to_the_original() {
        let (_dir, vault) = vault();
        // The case the baseline exists for: without it this undo would delete top.md.
        let commit = vault.write("top.md", "clobbered\n").unwrap().unwrap();
        vault.undo(&commit).unwrap();
        assert_eq!(vault.read("top.md").unwrap(), "top\n");
    }

    #[test]
    fn reads_a_note() {
        let (_dir, vault) = vault();
        assert_eq!(vault.read("top.md").unwrap(), "top\n");
    }

    #[test]
    fn writes_and_commits() {
        let (_dir, vault) = vault();
        let commit = vault.write("top.md", "changed\n").unwrap();
        assert!(commit.is_some());
        assert_eq!(vault.read("top.md").unwrap(), "changed\n");
        assert!(!vault.history().is_dirty().unwrap(), "write left the tree dirty");
    }

    #[test]
    fn creates_a_note_but_refuses_to_clobber() {
        let (_dir, vault) = vault();
        vault.create_file("fresh.md", "new\n").unwrap();
        assert_eq!(vault.read("fresh.md").unwrap(), "new\n");

        assert!(matches!(
            vault.create_file("fresh.md", "again\n"),
            Err(VaultError::Exists(_))
        ));
        assert_eq!(vault.read("fresh.md").unwrap(), "new\n", "clobbered anyway");
    }

    #[test]
    fn edits_one_exact_occurrence() {
        let (_dir, vault) = vault();
        vault.write("top.md", "alpha\nbeta\ngamma\n").unwrap();

        vault.edit("top.md", "beta", "BETA").unwrap();
        assert_eq!(vault.read("top.md").unwrap(), "alpha\nBETA\ngamma\n");
    }

    #[test]
    fn refuses_an_edit_that_matches_nothing() {
        let (_dir, vault) = vault();
        assert!(matches!(
            vault.edit("top.md", "absent", "x"),
            Err(VaultError::NoMatch(_))
        ));
        assert_eq!(vault.read("top.md").unwrap(), "top\n", "file was touched anyway");
    }

    #[test]
    fn refuses_an_ambiguous_edit_rather_than_guessing() {
        let (_dir, vault) = vault();
        vault.write("top.md", "same\nsame\n").unwrap();

        assert!(matches!(
            vault.edit("top.md", "same", "changed"),
            Err(VaultError::AmbiguousMatch(2))
        ));
        assert_eq!(vault.read("top.md").unwrap(), "same\nsame\n", "edited anyway");
    }

    #[test]
    fn an_edit_can_be_undone() {
        let (_dir, vault) = vault();
        let commit = vault.edit("top.md", "top", "changed").unwrap().unwrap();
        vault.undo(&commit).unwrap();
        assert_eq!(vault.read("top.md").unwrap(), "top\n");
    }

    #[test]
    fn creates_nested_folders() {
        let (dir, vault) = vault();
        vault.create_folder("a/b/c").unwrap();
        assert!(dir.path().join("a/b/c").is_dir());
    }

    #[test]
    fn moves_a_note() {
        let (_dir, vault) = vault();
        vault.move_path("top.md", "notes/moved.md").unwrap();
        assert_eq!(vault.read("notes/moved.md").unwrap(), "top\n");
        assert!(vault.read("top.md").is_err());
    }

    #[test]
    fn deletes_and_undoes() {
        let (_dir, vault) = vault();
        let commit = vault.delete("top.md").unwrap().unwrap();
        assert!(vault.read("top.md").is_err());

        vault.undo(&commit).unwrap();
        assert_eq!(vault.read("top.md").unwrap(), "top\n");
    }

    #[test]
    fn undo_restores_an_overwritten_note() {
        let (_dir, vault) = vault();
        let commit = vault.write("top.md", "clobbered\n").unwrap().unwrap();
        vault.undo(&commit).unwrap();
        assert_eq!(vault.read("top.md").unwrap(), "top\n");
    }

    #[test]
    fn lists_folders_first_and_hides_non_notes() {
        let (_dir, vault) = vault();
        let entries = vault.list(None).unwrap();
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();

        assert_eq!(names, vec!["notes", "top.md"], "unexpected listing");
        assert!(entries[0].is_directory);
    }

    #[test]
    fn listing_hides_the_git_directory() {
        let (_dir, vault) = vault();
        assert!(
            !vault.list(None).unwrap().iter().any(|e| e.name == ".git"),
            "our own history leaked into the listing"
        );
    }

    #[test]
    fn lists_a_subfolder() {
        let (_dir, vault) = vault();
        let entries = vault.list(Some("notes")).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "notes/nested.md");
    }

    // MARK: - Confinement reaches every entry point

    #[test]
    fn every_mutating_method_refuses_to_escape() {
        let (dir, vault) = vault();
        let outside = dir.path().parent().unwrap().join("escaped.md");

        assert!(vault.read("../escaped.md").is_err());
        assert!(vault.write("../escaped.md", "x").is_err());
        assert!(vault.create_file("../escaped.md", "x").is_err());
        assert!(vault.create_folder("../escaped").is_err());
        assert!(vault.move_path("top.md", "../escaped.md").is_err());
        assert!(vault.delete("../escaped.md").is_err());
        assert!(vault.list(Some("..")).is_err());

        assert!(!outside.exists(), "a write escaped the vault");
        assert_eq!(vault.read("top.md").unwrap(), "top\n", "source was moved out");
    }

    #[test]
    fn create_folder_cannot_escape_through_a_missing_parent() {
        let (_dir, vault) = vault();
        // Exercises the `mkdir -p` path, which confines the deepest existing ancestor.
        assert!(vault.create_folder("a/../../escaped").is_err());
    }

    #[test]
    fn refuses_to_delete_the_vault_itself() {
        let (dir, vault) = vault();
        assert!(vault.delete(".").is_err());
        assert!(dir.path().join("top.md").exists());
    }
}
