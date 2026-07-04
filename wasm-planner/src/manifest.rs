use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::LocalPackageManifest;

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("source manifest path must be relative and non-empty, got `{0}`")]
    InvalidPath(String),
    #[error("source manifest only supports regular files, got `{kind}` at `{path}`")]
    UnsupportedEntryKind { path: String, kind: String },
    #[error("source manifest sha256 must be 64 lowercase hex characters at `{path}`")]
    InvalidSha256 { path: String },
    #[error("source manifest contains duplicate path `{0}`")]
    DuplicatePath(String),
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq, Ord, PartialOrd)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceManifestEntry {
    pub path: String,
    pub kind: String,
    pub sha256: String,
}

pub fn normalize_manifests(mut manifests: Vec<LocalPackageManifest>) -> Vec<LocalPackageManifest> {
    manifests.iter_mut().for_each(|manifest| {
        manifest.path = normalize_path(&manifest.path);
    });
    manifests.sort_by(|a, b| a.path.cmp(&b.path));
    manifests
}

pub fn source_tree_digest(entries: &[SourceManifestEntry]) -> Result<String, ManifestError> {
    let normalized = normalize_source_manifest(entries)?;
    let bytes = serde_json::to_vec(&normalized).expect("source manifest serialization failed");
    Ok(format!("blake3:{}", blake3::hash(&bytes).to_hex()))
}

pub fn normalize_source_manifest(
    entries: &[SourceManifestEntry],
) -> Result<Vec<SourceManifestEntry>, ManifestError> {
    let mut normalized = entries
        .iter()
        .map(normalize_source_manifest_entry)
        .collect::<Result<Vec<_>, _>>()?;

    normalized.sort();

    let mut seen = BTreeSet::new();
    for entry in &normalized {
        if !seen.insert(entry.path.clone()) {
            return Err(ManifestError::DuplicatePath(entry.path.clone()));
        }
    }

    Ok(normalized)
}

fn normalize_source_manifest_entry(
    entry: &SourceManifestEntry,
) -> Result<SourceManifestEntry, ManifestError> {
    let path = normalize_path(&entry.path);
    if path == "." || path.starts_with('/') || path.split('/').any(|part| part == "..") {
        return Err(ManifestError::InvalidPath(entry.path.clone()));
    }

    if entry.kind != "regular" {
        return Err(ManifestError::UnsupportedEntryKind {
            path,
            kind: entry.kind.clone(),
        });
    }

    if entry.sha256.len() != 64
        || !entry
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(ManifestError::InvalidSha256 { path });
    }

    Ok(SourceManifestEntry {
        path,
        kind: entry.kind.clone(),
        sha256: entry.sha256.clone(),
    })
}

fn normalize_path(path: &str) -> String {
    let trimmed = path.trim().trim_start_matches("./");
    if trimmed.is_empty() {
        ".".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifests_are_sorted_by_path() {
        let manifests = vec![
            LocalPackageManifest {
                path: "./b".to_string(),
                cabal_text: "name: b\nversion: 0".to_string(),
            },
            LocalPackageManifest {
                path: "a".to_string(),
                cabal_text: "name: a\nversion: 0".to_string(),
            },
        ];

        let paths = normalize_manifests(manifests)
            .into_iter()
            .map(|manifest| manifest.path)
            .collect::<Vec<_>>();

        assert_eq!(paths, vec!["a", "b"]);
    }

    #[test]
    fn source_tree_digest_is_independent_of_manifest_order() {
        let first = vec![
            SourceManifestEntry {
                path: "src/B.hs".to_string(),
                kind: "regular".to_string(),
                sha256: "b".repeat(64),
            },
            SourceManifestEntry {
                path: "./src/A.hs".to_string(),
                kind: "regular".to_string(),
                sha256: "a".repeat(64),
            },
        ];
        let mut second = first.clone();
        second.reverse();

        assert_eq!(
            source_tree_digest(&first).unwrap(),
            source_tree_digest(&second).unwrap()
        );
    }

    #[test]
    fn source_manifest_rejects_duplicate_paths() {
        let entries = vec![
            SourceManifestEntry {
                path: "src/A.hs".to_string(),
                kind: "regular".to_string(),
                sha256: "a".repeat(64),
            },
            SourceManifestEntry {
                path: "./src/A.hs".to_string(),
                kind: "regular".to_string(),
                sha256: "b".repeat(64),
            },
        ];

        assert!(matches!(
            normalize_source_manifest(&entries),
            Err(ManifestError::DuplicatePath(path)) if path == "src/A.hs"
        ));
    }
}
