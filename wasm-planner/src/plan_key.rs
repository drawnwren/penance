use serde::Serialize;
use std::collections::BTreeMap;

use crate::cabal_project::CabalProject;
use crate::skeleton::LocalPackage;
use crate::{LocalPackageManifest, NormalizeInput};

pub fn project_key(
    input: &NormalizeInput,
    src_tree_digest: &str,
    flags: &BTreeMap<String, bool>,
    manifests: &[LocalPackageManifest],
    local_packages: &[LocalPackage],
    cabal_project: &CabalProject,
) -> String {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct CanonicalProject<'a> {
        src_tree_digest: &'a str,
        compiler: &'a str,
        index_state: &'a str,
        cabal_project_text: &'a str,
        cabal_project_packages: &'a [String],
        local_package_manifests: &'a [LocalPackageManifest],
        local_packages: &'a [LocalPackage],
        flags: &'a BTreeMap<String, bool>,
        materialization_mode: &'a str,
        granularity: &'a str,
    }

    digest_json(&CanonicalProject {
        src_tree_digest,
        compiler: &input.compiler,
        index_state: &input.index_state,
        cabal_project_text: &input.cabal_project_text,
        cabal_project_packages: &cabal_project.packages,
        local_package_manifests: manifests,
        local_packages,
        flags,
        materialization_mode: &input.materialization_mode,
        granularity: &input.granularity,
    })
}

pub fn plan_cache_key(
    project_key: &str,
    compiler: &str,
    index_state: &str,
    granularity: &str,
    flags: &BTreeMap<String, bool>,
    local_packages: &[LocalPackage],
) -> String {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct PlanKey<'a> {
        project_key: &'a str,
        compiler: &'a str,
        index_state: &'a str,
        granularity: &'a str,
        flags: &'a BTreeMap<String, bool>,
        local_packages: &'a [LocalPackage],
    }

    digest_json(&PlanKey {
        project_key,
        compiler,
        index_state,
        granularity,
        flags,
        local_packages,
    })
}

fn digest_json<T: Serialize>(value: &T) -> String {
    let bytes = serde_json::to_vec(value).expect("canonical key serialization failed");
    format!("blake3:{}", blake3::hash(&bytes).to_hex())
}
