use penance_wasm_planner::normalize_project_result;
use pretty_assertions::assert_eq;
use serde_json::json;

const SIMPLE_LIB_CABAL: &str = r#"
cabal-version: 3.8
name: simple-lib
version: 0.1.0.0
build-type: Simple
license: MIT

library
  exposed-modules: Simple
  hs-source-dirs: src
  build-depends: base >=4.18 && <5
  default-language: Haskell2010
"#;

const BACKPACK_SIGNATURES_CABAL: &str = r#"
cabal-version: 3.8
name: backpack-signatures
version: 0.1.0.0
build-type: Simple
license: MIT

library
  exposed-modules: UsesSignature
  signatures: Data.MyAbstractMap
  hs-source-dirs: src
  build-depends: base >=4.18 && <5
  default-language: Haskell2010
"#;

#[test]
fn normalizes_simple_library() {
    let input = json!({
        "srcTreeDigest": "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "compiler": "ghc-9.10.2",
        "indexState": "2026-04-01T00:00:00Z",
        "cabalProjectText": "packages: .\n",
        "localPackageManifests": [{
            "path": ".",
            "cabalText": SIMPLE_LIB_CABAL
        }],
        "flags": {
            "simple-lib:dev": false
        },
        "materializationMode": "dynamic",
        "granularity": "component"
    });

    let skeleton = normalize_project_result(&input.to_string()).unwrap();

    assert_eq!(skeleton.local_packages.len(), 1);
    assert_eq!(skeleton.local_packages[0].name, "simple-lib");
    assert_eq!(skeleton.local_packages[0].components, vec!["lib"]);
    assert_eq!(
        skeleton.local_packages[0].component_details[0].component,
        "lib"
    );
    assert_eq!(
        skeleton.local_packages[0].component_details[0].provided_modules,
        vec!["Simple"]
    );
    assert_eq!(skeleton.local_packages[0].provided_modules, vec!["Simple"]);
    assert!(skeleton.backpack.indefinite_units.is_empty());
    assert!(skeleton.expected_outputs.component_graph_drv);
    assert_eq!(skeleton.granularity, "component");
}

#[test]
fn normalizes_backpack_signature_library() {
    let input = json!({
        "srcTreeDigest": "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "compiler": "ghc-9.10.2",
        "indexState": "2026-04-01T00:00:00Z",
        "cabalProjectText": "packages: .\n",
        "localPackageManifests": [{
            "path": ".",
            "cabalText": BACKPACK_SIGNATURES_CABAL
        }],
        "flags": {},
        "materializationMode": "dynamic",
        "granularity": "module"
    });

    let skeleton = normalize_project_result(&input.to_string()).unwrap();

    assert_eq!(skeleton.local_packages[0].name, "backpack-signatures");
    assert_eq!(
        skeleton.local_packages[0].signatures,
        vec!["Data.MyAbstractMap"]
    );
    assert_eq!(skeleton.backpack.indefinite_units.len(), 1);
    assert_eq!(
        skeleton.backpack.indefinite_units[0].unit,
        "backpack-signatures:lib"
    );
    assert_eq!(
        skeleton.backpack.indefinite_units[0].required_signatures,
        vec!["Data.MyAbstractMap"]
    );
    assert!(skeleton.backpack.expected_instantiations.is_empty());
    assert_eq!(skeleton.granularity, "module");
}

#[test]
fn output_is_byte_identical_for_semantically_identical_input() {
    let first = json!({
        "srcTreeDigest": "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "compiler": "ghc-9.10.2",
        "indexState": "2026-04-01T00:00:00Z",
        "cabalProjectText": "packages: .\n",
        "localPackageManifests": [{
            "path": "./.",
            "cabalText": SIMPLE_LIB_CABAL
        }],
        "flags": {
            "Simple-Lib:DEV": false,
            "simple-lib:bench": true
        },
        "materializationMode": "dynamic",
        "granularity": "component"
    });

    let second = json!({
        "granularity": "component",
        "materializationMode": "dynamic",
        "flags": {
            "simple-lib:bench": true,
            "simple-lib:dev": false
        },
        "localPackageManifests": [{
            "cabalText": SIMPLE_LIB_CABAL,
            "path": "."
        }],
        "cabalProjectText": "packages: .\n",
        "indexState": "2026-04-01T00:00:00Z",
        "compiler": "ghc-9.10.2",
        "srcTreeDigest": "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    });

    let first = penance_wasm_planner::normalize_project(&first.to_string());
    let second = penance_wasm_planner::normalize_project(&second.to_string());

    assert_eq!(first, second);
}

#[test]
fn derives_src_tree_digest_from_source_manifest() {
    let first = json!({
        "compiler": "ghc-9.10.2",
        "indexState": "2026-04-01T00:00:00Z",
        "cabalProjectText": "packages: .\n",
        "sourceManifest": [
            {
                "path": "src/Simple.hs",
                "kind": "regular",
                "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
                "path": "simple-lib.cabal",
                "kind": "regular",
                "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            }
        ],
        "localPackageManifests": [{
            "path": ".",
            "cabalText": SIMPLE_LIB_CABAL
        }],
        "flags": {},
        "materializationMode": "dynamic",
        "granularity": "component"
    });
    let second = json!({
        "compiler": "ghc-9.10.2",
        "indexState": "2026-04-01T00:00:00Z",
        "cabalProjectText": "packages: .\n",
        "sourceManifest": [
            {
                "path": "simple-lib.cabal",
                "kind": "regular",
                "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            },
            {
                "path": "./src/Simple.hs",
                "kind": "regular",
                "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }
        ],
        "localPackageManifests": [{
            "path": ".",
            "cabalText": SIMPLE_LIB_CABAL
        }],
        "flags": {},
        "materializationMode": "dynamic",
        "granularity": "component"
    });

    let first = normalize_project_result(&first.to_string()).unwrap();
    let second = normalize_project_result(&second.to_string()).unwrap();

    assert_eq!(first.project_key, second.project_key);
    assert!(first.project_key.starts_with("blake3:"));
}

#[test]
fn rejects_mismatched_src_tree_digest_and_source_manifest() {
    let input = json!({
        "srcTreeDigest": "blake3:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "compiler": "ghc-9.10.2",
        "indexState": "2026-04-01T00:00:00Z",
        "cabalProjectText": "packages: .\n",
        "sourceManifest": [{
            "path": "simple-lib.cabal",
            "kind": "regular",
            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }],
        "localPackageManifests": [{
            "path": ".",
            "cabalText": SIMPLE_LIB_CABAL
        }],
        "flags": {},
        "materializationMode": "dynamic",
        "granularity": "component"
    });

    let error = normalize_project_result(&input.to_string()).unwrap_err();
    assert!(error.to_string().contains("does not match digest"));
}
