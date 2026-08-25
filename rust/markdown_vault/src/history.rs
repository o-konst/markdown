//! Vault history, backed by a plain git repository inside the vault.
//!
//! Undo for agent writes is the reason this exists. A hand-rolled journal would have to
//! reinvent diffing, atomicity, and crash recovery; git already has all three, and the
//! result is inspectable with tools the user already owns.
//!
//! The repository is strictly local. Nothing here adds a remote or pushes — that is the
//! user's business, not ours.

use std::path::Path;

use git2::{IndexAddOption, Repository, RepositoryInitOptions, Signature};

#[derive(Debug)]
pub enum HistoryError {
    Git(git2::Error),
    /// A revert could not be applied cleanly; the working tree is untouched.
    Conflict(String),
}

impl std::fmt::Display for HistoryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Git(err) => write!(f, "history: {}", err.message()),
            Self::Conflict(what) => write!(f, "cannot undo cleanly: {what}"),
        }
    }
}

impl std::error::Error for HistoryError {}

impl From<git2::Error> for HistoryError {
    fn from(err: git2::Error) -> Self {
        Self::Git(err)
    }
}

/// One commit, for the history UI and for undo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: String,
    pub message: String,
    /// Seconds since the epoch.
    pub time: i64,
}

pub struct History {
    repo: Repository,
}

impl History {
    /// Opens the vault's repository, creating it on first use.
    ///
    /// An existing repository is adopted as-is — a vault already under version control keeps
    /// its history rather than gaining a second one.
    pub fn open_or_init(root: &Path) -> Result<Self, HistoryError> {
        let repo = match Repository::open(root) {
            Ok(repo) => repo,
            Err(_) => {
                let mut options = RepositoryInitOptions::new();
                options.no_reinit(true);
                Repository::init_opts(root, &options)?
            }
        };
        // This repo is a private undo journal, not a working copy meant for `git checkout`
        // by hand — undo must restore the exact bytes a write produced regardless of the
        // user's global `core.autocrlf`, so pin it locally rather than inheriting that.
        repo.config()?.set_bool("core.autocrlf", false)?;
        Ok(Self { repo })
    }

    /// True when the working tree has changes that are not yet committed.
    ///
    /// An agent turn refuses to start on a dirty tree, so its commits never entangle with
    /// edits the user has not saved.
    pub fn is_dirty(&self) -> Result<bool, HistoryError> {
        let mut options = git2::StatusOptions::new();
        options.include_untracked(true).include_ignored(false);
        Ok(!self.repo.statuses(Some(&mut options))?.is_empty())
    }

    /// Stages everything and commits, returning the new commit id.
    ///
    /// `Ok(None)` means the tree was already clean — saving an unchanged file is not an
    /// error, it just is not a commit.
    pub fn commit_all(&self, message: &str) -> Result<Option<String>, HistoryError> {
        let mut index = self.repo.index()?;
        index.add_all(["*"].iter(), IndexAddOption::DEFAULT, None)?;
        index.write()?;
        let tree_id = index.write_tree()?;

        let head = self.repo.head().ok().and_then(|h| h.peel_to_commit().ok());
        if let Some(parent) = &head {
            if parent.tree_id() == tree_id {
                return Ok(None);
            }
        }

        let tree = self.repo.find_tree(tree_id)?;
        let signature = self.signature()?;
        let parents: Vec<&git2::Commit> = head.iter().collect();

        let id = self.repo.commit(
            Some("HEAD"),
            &signature,
            &signature,
            message,
            &tree,
            &parents,
        )?;
        Ok(Some(id.to_string()))
    }

    /// Undoes `commit` by applying its inverse as a *new* commit.
    ///
    /// History is preserved rather than rewritten, so an undo is itself undoable and nothing
    /// the user did earlier disappears.
    pub fn revert(&self, commit_id: &str) -> Result<String, HistoryError> {
        let oid = git2::Oid::from_str(commit_id)?;
        let commit = self.repo.find_commit(oid)?;

        self.repo.revert(&commit, None)?;

        let mut index = self.repo.index()?;
        if index.has_conflicts() {
            // Leave the caller a clean tree rather than a half-applied undo.
            self.repo.cleanup_state()?;
            self.repo.checkout_head(Some(
                git2::build::CheckoutBuilder::new().force(),
            ))?;
            return Err(HistoryError::Conflict(format!(
                "commit {} overlaps later changes",
                &commit_id[..commit_id.len().min(8)]
            )));
        }
        index.write()?;

        let summary = commit.summary().ok().flatten().unwrap_or("change").to_owned();
        let id = self.commit_all(&format!("Undo: {summary}"))?;
        self.repo.cleanup_state()?;

        id.ok_or_else(|| HistoryError::Conflict("nothing to undo".into()))
    }

    /// Most recent commits, newest first.
    pub fn log(&self, limit: usize) -> Result<Vec<Entry>, HistoryError> {
        let mut walk = self.repo.revwalk()?;
        if walk.push_head().is_err() {
            return Ok(Vec::new()); // No commits yet.
        }
        walk.set_sorting(git2::Sort::TIME)?;

        let mut entries = Vec::new();
        for oid in walk.take(limit) {
            let commit = self.repo.find_commit(oid?)?;
            entries.push(Entry {
                id: commit.id().to_string(),
                message: commit.summary().ok().flatten().unwrap_or_default().to_owned(),
                time: commit.time().seconds(),
            });
        }
        Ok(entries)
    }

    /// Prefers the user's own git identity so vault history looks like their other repos.
    fn signature(&self) -> Result<Signature<'static>, HistoryError> {
        if let Ok(signature) = self.repo.signature() {
            return Ok(signature.to_owned());
        }
        Ok(Signature::now("Markdown", "markdown@localhost")?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn vault() -> (TempDir, History) {
        let dir = TempDir::new().unwrap();
        let history = History::open_or_init(dir.path()).unwrap();
        (dir, history)
    }

    #[test]
    fn initialises_a_repository_on_first_use() {
        let (dir, _history) = vault();
        assert!(dir.path().join(".git").exists());
    }

    #[test]
    fn adopts_an_existing_repository() {
        let dir = TempDir::new().unwrap();
        let first = History::open_or_init(dir.path()).unwrap();
        fs::write(dir.path().join("a.md"), "one").unwrap();
        first.commit_all("first").unwrap();
        drop(first);

        let second = History::open_or_init(dir.path()).unwrap();
        assert_eq!(second.log(10).unwrap().len(), 1, "existing history was discarded");
    }

    #[test]
    fn commits_a_new_file() {
        let (dir, history) = vault();
        fs::write(dir.path().join("a.md"), "one").unwrap();

        let id = history.commit_all("add a.md").unwrap();
        assert!(id.is_some());
        assert!(!history.is_dirty().unwrap());

        let log = history.log(10).unwrap();
        assert_eq!(log.len(), 1);
        assert_eq!(log[0].message, "add a.md");
    }

    #[test]
    fn an_unchanged_tree_is_not_a_commit() {
        let (dir, history) = vault();
        fs::write(dir.path().join("a.md"), "one").unwrap();
        history.commit_all("first").unwrap();

        assert_eq!(history.commit_all("again").unwrap(), None);
        assert_eq!(history.log(10).unwrap().len(), 1);
    }

    #[test]
    fn reports_a_dirty_tree() {
        let (dir, history) = vault();
        assert!(!history.is_dirty().unwrap());

        fs::write(dir.path().join("a.md"), "one").unwrap();
        assert!(history.is_dirty().unwrap(), "an untracked file is a dirty tree");

        history.commit_all("first").unwrap();
        assert!(!history.is_dirty().unwrap());
    }

    #[test]
    fn undo_restores_the_previous_bytes_exactly() {
        let (dir, history) = vault();
        let note = dir.path().join("a.md");

        fs::write(&note, "original\n").unwrap();
        history.commit_all("write original").unwrap();

        fs::write(&note, "clobbered by the agent\n").unwrap();
        let bad = history.commit_all("agent edit").unwrap().unwrap();

        history.revert(&bad).unwrap();
        assert_eq!(fs::read_to_string(&note).unwrap(), "original\n");
    }

    #[test]
    fn undo_restores_a_deleted_file() {
        let (dir, history) = vault();
        let note = dir.path().join("a.md");

        fs::write(&note, "keep me\n").unwrap();
        history.commit_all("add").unwrap();

        fs::remove_file(&note).unwrap();
        let deletion = history.commit_all("agent deleted a.md").unwrap().unwrap();
        assert!(!note.exists());

        history.revert(&deletion).unwrap();
        assert_eq!(fs::read_to_string(&note).unwrap(), "keep me\n");
    }

    #[test]
    fn undo_is_itself_a_commit_so_history_is_preserved() {
        let (dir, history) = vault();
        fs::write(dir.path().join("a.md"), "one").unwrap();
        history.commit_all("first").unwrap();
        fs::write(dir.path().join("a.md"), "two").unwrap();
        let second = history.commit_all("second").unwrap().unwrap();

        history.revert(&second).unwrap();

        let log = history.log(10).unwrap();
        assert_eq!(log.len(), 3, "undo should add a commit, not rewrite history");
        assert!(log[0].message.starts_with("Undo:"), "{:?}", log[0].message);
    }

    #[test]
    fn log_is_empty_before_the_first_commit() {
        let (_dir, history) = vault();
        assert!(history.log(10).unwrap().is_empty());
    }
}
