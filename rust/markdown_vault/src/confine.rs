//! The security boundary.
//!
//! Every path that reaches this crate originates outside it — typed by a user, or produced
//! by a language model that read it off the internet. [`resolve_in`] is the one place that
//! turns such a string into a `PathBuf`, and it is the only reason the rest of the crate can
//! treat paths as safe.
//!
//! The contract is deliberately narrow: **paths are always vault-relative**. There is no way
//! to express a location outside the vault, so there is nothing to get wrong at the call
//! site. A leading `/` is a convenience (`/notes/a.md` means `notes/a.md`), not an escape,
//! and `..` is refused outright rather than normalised.
//!
//! Symlinks are handled by canonicalising before the containment check, so a link inside the
//! vault pointing outside it resolves outside and is rejected. For a file that does not
//! exist yet the *parent* is canonicalised and checked, which closes the same hole for
//! writes into a symlinked directory.

use std::fmt;
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfineError {
    /// The path was empty, or only slashes and whitespace.
    Empty,
    /// A `..` component, or a root/drive prefix in what must be a relative path.
    Traversal,
    /// An interior NUL, which would be truncated by the platform's syscalls.
    InteriorNul,
    /// The vault root itself could not be read.
    RootUnavailable(String),
    /// The path resolved cleanly but nothing is there.
    NotFound(String),
    /// The containing directory does not exist, so a file cannot be created in it.
    ParentMissing(String),
    /// The path resolved to somewhere outside the vault.
    Escapes(String),
}

impl fmt::Display for ConfineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => write!(f, "path must not be empty"),
            Self::Traversal => write!(f, "path must be relative to the vault and must not contain `..`"),
            Self::InteriorNul => write!(f, "path must not contain a NUL byte"),
            Self::RootUnavailable(why) => write!(f, "vault is not accessible: {why}"),
            Self::NotFound(path) => write!(f, "no such file in the vault: {path}"),
            Self::ParentMissing(path) => write!(f, "containing folder does not exist: {path}"),
            Self::Escapes(path) => write!(f, "path escapes the vault: {path}"),
        }
    }
}

impl std::error::Error for ConfineError {}

/// Resolves `input` against `root`, guaranteeing the result stays inside the vault.
///
/// `must_exist` distinguishes reads (the file has to be there) from writes (it may not be
/// yet, but its parent must).
pub fn resolve_in(root: &Path, input: &str, must_exist: bool) -> Result<PathBuf, ConfineError> {
    if input.contains('\0') {
        return Err(ConfineError::InteriorNul);
    }

    // Vault-relative by contract, so a leading slash is stripped rather than honoured.
    let relative = input.trim().trim_start_matches('/');
    if relative.is_empty() {
        return Err(ConfineError::Empty);
    }

    let raw = Path::new(relative);
    for component in raw.components() {
        match component {
            // Refused, not normalised: `a/../b` is a mistake worth surfacing, and
            // normalising it here would mean two ideas of what the path is.
            Component::ParentDir => return Err(ConfineError::Traversal),
            // Survives the strip above only on Windows (`C:\`, `\\server\share`).
            Component::Prefix(_) | Component::RootDir => return Err(ConfineError::Traversal),
            Component::CurDir | Component::Normal(_) => {}
        }
    }

    let root = root
        .canonicalize()
        .map_err(|why| ConfineError::RootUnavailable(why.to_string()))?;
    let candidate = root.join(raw);

    let resolved = if candidate.exists() {
        candidate
            .canonicalize()
            .map_err(|why| ConfineError::RootUnavailable(why.to_string()))?
    } else if must_exist {
        return Err(ConfineError::NotFound(relative.to_owned()));
    } else {
        // Nothing to canonicalise yet, so resolve the parent and re-attach the name.
        let parent = candidate
            .parent()
            .ok_or_else(|| ConfineError::ParentMissing(relative.to_owned()))?;
        let file_name = candidate
            .file_name()
            .ok_or_else(|| ConfineError::Empty)?;
        let parent = parent
            .canonicalize()
            .map_err(|_| ConfineError::ParentMissing(relative.to_owned()))?;

        // Checked separately: a symlinked parent could otherwise place the new file outside.
        if !parent.starts_with(&root) {
            return Err(ConfineError::Escapes(relative.to_owned()));
        }
        parent.join(file_name)
    };

    // `starts_with` compares whole components, so `/vault-evil` is not inside `/vault`.
    if !resolved.starts_with(&root) {
        return Err(ConfineError::Escapes(relative.to_owned()));
    }

    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    /// A vault with a note, a nested note, and an `outside` sibling to try to reach.
    fn vault() -> (TempDir, PathBuf) {
        let dir = TempDir::new().unwrap();
        let root = dir.path().join("vault");
        fs::create_dir_all(root.join("notes")).unwrap();
        fs::write(root.join("top.md"), "top").unwrap();
        fs::write(root.join("notes/nested.md"), "nested").unwrap();

        fs::create_dir_all(dir.path().join("outside")).unwrap();
        fs::write(dir.path().join("outside/secret.md"), "secret").unwrap();
        (dir, root)
    }

    #[test]
    fn resolves_a_plain_relative_path() {
        let (_dir, root) = vault();
        let resolved = resolve_in(&root, "top.md", true).unwrap();
        assert_eq!(fs::read_to_string(resolved).unwrap(), "top");
    }

    #[test]
    fn resolves_a_nested_path() {
        let (_dir, root) = vault();
        let resolved = resolve_in(&root, "notes/nested.md", true).unwrap();
        assert_eq!(fs::read_to_string(resolved).unwrap(), "nested");
    }

    #[test]
    fn treats_a_leading_slash_as_vault_relative() {
        let (_dir, root) = vault();
        let rooted = resolve_in(&root, "/notes/nested.md", true).unwrap();
        let bare = resolve_in(&root, "notes/nested.md", true).unwrap();
        assert_eq!(rooted, bare);
    }

    #[test]
    fn allows_a_current_dir_component() {
        let (_dir, root) = vault();
        assert!(resolve_in(&root, "./top.md", true).is_ok());
    }

    // MARK: - Refusals

    #[test]
    fn rejects_empty_and_slash_only_input() {
        let (_dir, root) = vault();
        for input in ["", "   ", "/", "///"] {
            assert_eq!(resolve_in(&root, input, true), Err(ConfineError::Empty), "{input:?}");
        }
    }

    #[test]
    fn rejects_parent_traversal() {
        let (_dir, root) = vault();
        for input in [
            "../outside/secret.md",
            "..",
            "notes/../../outside/secret.md",
            "/../outside/secret.md",
            "notes/..",
        ] {
            assert_eq!(resolve_in(&root, input, true), Err(ConfineError::Traversal), "{input:?}");
        }
    }

    #[test]
    fn rejects_interior_nul() {
        let (_dir, root) = vault();
        assert_eq!(
            resolve_in(&root, "top.md\0.txt", true),
            Err(ConfineError::InteriorNul)
        );
    }

    #[test]
    fn an_absolute_path_cannot_reach_outside() {
        let (dir, root) = vault();
        let absolute = dir.path().join("outside/secret.md");
        let result = resolve_in(&root, absolute.to_str().unwrap(), true);
        // Unix: only the leading `/` is stripped, landing on a relative path that is nowhere
        // in the vault. Windows: a drive prefix (`C:\`) survives the strip and is refused
        // outright by the Prefix/RootDir check — a different, equally safe, rejection.
        #[cfg(not(windows))]
        assert!(
            matches!(result, Err(ConfineError::NotFound(_))),
            "expected NotFound, got {result:?}"
        );
        #[cfg(windows)]
        assert!(
            matches!(result, Err(ConfineError::Traversal)),
            "expected Traversal, got {result:?}"
        );
    }

    #[test]
    fn percent_encoding_is_not_decoded() {
        let (_dir, root) = vault();
        // `%2e%2e` must stay a literal file name, never become `..`.
        let result = resolve_in(&root, "%2e%2e/secret.md", true);
        assert!(
            matches!(result, Err(ConfineError::NotFound(_))),
            "expected NotFound, got {result:?}"
        );
    }

    /// Creates a symlink to `target` at `link`, working on both platforms.
    ///
    /// On Windows, creating a symlink needs elevation or Developer Mode — neither of which is
    /// guaranteed on a dev box or CI runner — so a permission failure there is reported and
    /// the test is skipped rather than failed; it says nothing about the security check under
    /// test, which uses `canonicalize()` and treats a real reparse point the same on either OS.
    fn try_symlink(target: &Path, link: &Path, target_is_dir: bool) -> bool {
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(target, link).unwrap();
            true
        }
        #[cfg(windows)]
        {
            let result = if target_is_dir {
                std::os::windows::fs::symlink_dir(target, link)
            } else {
                std::os::windows::fs::symlink_file(target, link)
            };
            match result {
                Ok(()) => true,
                Err(err) => {
                    eprintln!(
                        "skipping: could not create a symlink on this Windows host ({err}); \
                         needs elevation or Developer Mode"
                    );
                    false
                }
            }
        }
    }

    #[test]
    fn rejects_a_symlink_pointing_out_of_the_vault() {
        let (dir, root) = vault();
        if !try_symlink(&dir.path().join("outside/secret.md"), &root.join("escape.md"), false) {
            return;
        }

        let result = resolve_in(&root, "escape.md", true);
        assert!(
            matches!(result, Err(ConfineError::Escapes(_))),
            "expected Escapes, got {result:?}"
        );
    }

    #[test]
    fn rejects_a_symlinked_directory_pointing_out_of_the_vault() {
        let (dir, root) = vault();
        if !try_symlink(&dir.path().join("outside"), &root.join("linked"), true) {
            return;
        }

        // Reading through the link.
        assert!(matches!(
            resolve_in(&root, "linked/secret.md", true),
            Err(ConfineError::Escapes(_))
        ));
        // And creating a *new* file through it, where there is nothing to canonicalise.
        assert!(matches!(
            resolve_in(&root, "linked/planted.md", false),
            Err(ConfineError::Escapes(_))
        ));
    }

    #[test]
    fn a_sibling_directory_sharing_a_prefix_is_not_inside() {
        let dir = TempDir::new().unwrap();
        let root = dir.path().join("vault");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(dir.path().join("vault-evil")).unwrap();
        fs::write(dir.path().join("vault-evil/secret.md"), "secret").unwrap();

        if !try_symlink(&dir.path().join("vault-evil"), &root.join("link"), true) {
            return;
        }

        // Guards the string-prefix bug: `/vault-evil` starts with `/vault` as text.
        assert!(matches!(
            resolve_in(&root, "link/secret.md", true),
            Err(ConfineError::Escapes(_))
        ));
    }

    // MARK: - Writes to paths that do not exist yet

    #[test]
    fn allows_a_new_file_in_an_existing_folder() {
        let (_dir, root) = vault();
        let resolved = resolve_in(&root, "notes/fresh.md", false).unwrap();
        assert!(resolved.starts_with(root.canonicalize().unwrap()));
        assert!(!resolved.exists());
    }

    #[test]
    fn refuses_a_new_file_in_a_missing_folder() {
        let (_dir, root) = vault();
        assert!(matches!(
            resolve_in(&root, "no/such/folder/fresh.md", false),
            Err(ConfineError::ParentMissing(_))
        ));
    }

    #[test]
    fn must_exist_distinguishes_reads_from_writes() {
        let (_dir, root) = vault();
        assert!(matches!(
            resolve_in(&root, "notes/fresh.md", true),
            Err(ConfineError::NotFound(_))
        ));
        assert!(resolve_in(&root, "notes/fresh.md", false).is_ok());
    }

    #[test]
    fn reports_an_unusable_vault_root() {
        let dir = TempDir::new().unwrap();
        let missing = dir.path().join("not-a-vault");
        assert!(matches!(
            resolve_in(&missing, "top.md", true),
            Err(ConfineError::RootUnavailable(_))
        ));
    }
}
