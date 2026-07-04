pub mod backpack;
pub mod cabal_file;
pub mod cabal_project;
pub mod flags;
pub mod manifest;
pub mod plan_key;
pub mod skeleton;

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use cabal_file::parse_cabal_file;
use cabal_project::parse_cabal_project;
use flags::normalize_flags;
use manifest::{normalize_manifests, source_tree_digest, SourceManifestEntry};
use plan_key::{plan_cache_key, project_key};
use skeleton::{BackpackSkeleton, ExpectedOutputs, LocalPackage, ProjectSkeleton};

#[derive(Debug, thiserror::Error)]
pub enum PlannerError {
    #[error("invalid input JSON: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("{0}")]
    CabalProject(#[from] cabal_project::CabalProjectError),
    #[error("{0}")]
    CabalFile(#[from] cabal_file::CabalFileError),
    #[error("{0}")]
    Manifest(#[from] manifest::ManifestError),
    #[error("unsupported granularity `{0}`; expected `component` or `module`")]
    UnsupportedGranularity(String),
    #[error("unsupported materializationMode `{0}`; expected `dynamic`")]
    UnsupportedMaterializationMode(String),
    #[error("srcTreeDigest must be a blake3 digest, got `{0}`")]
    UnsupportedDigest(String),
    #[error("input must include either srcTreeDigest or sourceManifest")]
    MissingDigest,
    #[error(
        "srcTreeDigest `{provided}` does not match digest derived from sourceManifest `{computed}`"
    )]
    DigestMismatch { provided: String, computed: String },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NormalizeInput {
    #[serde(default)]
    pub src_tree_digest: Option<String>,
    #[serde(default)]
    pub source_manifest: Vec<SourceManifestEntry>,
    pub compiler: String,
    pub index_state: String,
    pub cabal_project_text: String,
    pub local_package_manifests: Vec<LocalPackageManifest>,
    #[serde(default)]
    pub flags: BTreeMap<String, bool>,
    pub materialization_mode: String,
    pub granularity: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalPackageManifest {
    pub path: String,
    pub cabal_text: String,
}

/// Single JSON-in, JSON-out entry point used by the Wasm shim and by tests.
///
/// This function is deliberately deterministic: the input is deserialized once,
/// normalized into sorted structures, and serialized once.
pub fn normalize_project(input: &str) -> String {
    match normalize_project_result(input) {
        Ok(skeleton) => {
            serde_json::to_string(&skeleton).expect("serializing ProjectSkeleton should never fail")
        }
        Err(err) => panic!("penance wasm planner failed: {err}"),
    }
}

#[cfg(target_arch = "wasm32")]
pub mod nix_wasm_abi {
    #[repr(transparent)]
    #[derive(Clone, Copy)]
    pub struct Value(u32);

    extern "C" {
        #[link_name = "copy_string"]
        fn host_copy_string(value: u32, ptr: *mut u8, max_len: usize) -> usize;

        #[link_name = "make_string"]
        fn host_make_string(ptr: *const u8, len: usize) -> Value;

        #[link_name = "panic"]
        fn host_panic(ptr: *const u8, len: usize) -> !;
    }

    impl Value {
        pub fn get_string(self) -> String {
            unsafe {
                let mut inline = [0; 1024];
                let len = host_copy_string(self.0, inline.as_mut_ptr(), inline.len());
                if len > inline.len() {
                    let mut heap = vec![0; len];
                    let actual = host_copy_string(self.0, heap.as_mut_ptr(), heap.len());
                    assert_eq!(actual, len);
                    String::from_utf8(heap).expect("Nix string should be UTF-8")
                } else {
                    String::from_utf8(inline[..len].to_vec()).expect("Nix string should be UTF-8")
                }
            }
        }

        pub fn make_string(value: &str) -> Self {
            unsafe { host_make_string(value.as_ptr(), value.len()) }
        }
    }

    pub fn panic_to_nix(message: &str) -> ! {
        unsafe { host_panic(message.as_ptr(), message.len()) }
    }
}

#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn nix_wasm_init_v1() {
    std::panic::set_hook(Box::new(|panic_info| {
        nix_wasm_abi::panic_to_nix(&panic_info.to_string());
    }));
}

#[cfg(target_arch = "wasm32")]
#[export_name = "normalize_project"]
pub extern "C" fn normalize_project_export(arg: nix_wasm_abi::Value) -> nix_wasm_abi::Value {
    let input = arg.get_string();
    match normalize_project_result(&input) {
        Ok(skeleton) => {
            let output = serde_json::to_string(&skeleton)
                .expect("serializing ProjectSkeleton should never fail");
            nix_wasm_abi::Value::make_string(&output)
        }
        Err(err) => nix_wasm_abi::panic_to_nix(&format!("penance wasm planner failed: {err}")),
    }
}

pub fn normalize_project_result(input: &str) -> Result<ProjectSkeleton, PlannerError> {
    let parsed: NormalizeInput = serde_json::from_str(input)?;

    let src_tree_digest = if parsed.source_manifest.is_empty() {
        parsed
            .src_tree_digest
            .clone()
            .ok_or(PlannerError::MissingDigest)?
    } else {
        let computed = source_tree_digest(&parsed.source_manifest)?;
        if let Some(provided) = &parsed.src_tree_digest {
            if provided != &computed {
                return Err(PlannerError::DigestMismatch {
                    provided: provided.clone(),
                    computed,
                });
            }
        }
        computed
    };
    if !src_tree_digest.starts_with("blake3:") {
        return Err(PlannerError::UnsupportedDigest(src_tree_digest));
    }
    if parsed.materialization_mode != "dynamic" {
        return Err(PlannerError::UnsupportedMaterializationMode(
            parsed.materialization_mode,
        ));
    }
    if parsed.granularity != "component" && parsed.granularity != "module" {
        return Err(PlannerError::UnsupportedGranularity(parsed.granularity));
    }

    let flags = normalize_flags(parsed.flags.clone());
    let manifests = normalize_manifests(parsed.local_package_manifests.clone());
    let cabal_project = parse_cabal_project(&parsed.cabal_project_text)?;

    let mut local_packages = Vec::new();
    let mut backpack_units = Vec::new();
    let mut expected_instantiations = Vec::new();

    for manifest in &manifests {
        let cabal = parse_cabal_file(&manifest.path, &manifest.cabal_text)?;
        let package = LocalPackage::from_cabal_package(&cabal);
        backpack_units.extend(BackpackSkeleton::units_from_package(&cabal));
        expected_instantiations.extend(BackpackSkeleton::instantiations_from_package(&cabal));
        local_packages.push(package);
    }

    local_packages.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| a.version.cmp(&b.version))
            .then_with(|| a.components.cmp(&b.components))
    });
    backpack_units.sort();
    expected_instantiations.sort();

    let canonical_key = project_key(
        &parsed,
        &src_tree_digest,
        &flags,
        &manifests,
        &local_packages,
        &cabal_project,
    );
    let cache_key = plan_cache_key(
        &canonical_key,
        &parsed.compiler,
        &parsed.index_state,
        &parsed.granularity,
        &flags,
        &local_packages,
    );

    Ok(ProjectSkeleton {
        project_key: canonical_key,
        local_packages,
        source_repos: cabal_project.source_repos,
        plan_cache_key: cache_key,
        planner_drv_inputs: Vec::new(),
        granularity: parsed.granularity,
        backpack: BackpackSkeleton {
            indefinite_units: backpack_units,
            expected_instantiations,
        },
        expected_outputs: ExpectedOutputs {
            component_graph_drv: true,
            module_graph_drv: true,
            backpack_graph_drv: true,
        },
    })
}
