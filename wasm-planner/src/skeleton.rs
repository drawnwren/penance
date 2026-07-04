use serde::{Deserialize, Serialize};

use crate::backpack::{instantiations_from_mixins, ExpectedInstantiation, IndefiniteUnit};
use crate::cabal_file::{CabalComponent, CabalPackage, ComponentKind};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSkeleton {
    pub project_key: String,
    pub local_packages: Vec<LocalPackage>,
    pub source_repos: Vec<std::collections::BTreeMap<String, String>>,
    pub plan_cache_key: String,
    pub planner_drv_inputs: Vec<String>,
    pub granularity: String,
    pub backpack: BackpackSkeleton,
    pub expected_outputs: ExpectedOutputs,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalPackage {
    pub name: String,
    pub version: String,
    pub components: Vec<String>,
    pub component_details: Vec<LocalComponent>,
    pub signatures: Vec<String>,
    pub required_signatures: Vec<String>,
    pub provided_modules: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalComponent {
    pub component: String,
    pub kind: String,
    pub provided_modules: Vec<String>,
    pub signatures: Vec<String>,
    pub required_signatures: Vec<String>,
    pub mixins: Vec<String>,
    pub reexported_modules: Vec<String>,
}

impl LocalPackage {
    pub fn from_cabal_package(package: &CabalPackage) -> Self {
        let mut components = Vec::new();
        let mut component_details = Vec::new();
        let mut signatures = Vec::new();
        let mut required_signatures = Vec::new();
        let mut provided_modules = Vec::new();

        for component in &package.components {
            components.push(component.id.clone());
            component_details.push(LocalComponent::from_cabal_component(component));
            signatures.extend(component.signatures.clone());
            required_signatures.extend(component.required_signatures.clone());
            provided_modules.extend(component.provided_modules.clone());
        }

        components.sort();
        components.dedup();
        component_details.sort();
        signatures.sort();
        signatures.dedup();
        required_signatures.sort();
        required_signatures.dedup();
        provided_modules.sort();
        provided_modules.dedup();

        Self {
            name: package.name.clone(),
            version: package.version.clone(),
            components,
            component_details,
            signatures,
            required_signatures,
            provided_modules,
        }
    }
}

impl LocalComponent {
    fn from_cabal_component(component: &CabalComponent) -> Self {
        Self {
            component: component.id.clone(),
            kind: component_kind_name(&component.kind).to_string(),
            provided_modules: component.provided_modules.clone(),
            signatures: component.signatures.clone(),
            required_signatures: component.required_signatures.clone(),
            mixins: component.mixins.clone(),
            reexported_modules: component.reexported_modules.clone(),
        }
    }
}

fn component_kind_name(kind: &ComponentKind) -> &'static str {
    match kind {
        ComponentKind::Library => "library",
        ComponentKind::Executable => "executable",
        ComponentKind::TestSuite => "test-suite",
        ComponentKind::Benchmark => "benchmark",
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackpackSkeleton {
    pub indefinite_units: Vec<IndefiniteUnit>,
    pub expected_instantiations: Vec<ExpectedInstantiation>,
}

impl BackpackSkeleton {
    pub fn units_from_package(package: &CabalPackage) -> Vec<IndefiniteUnit> {
        package
            .components
            .iter()
            .filter(|component| !component.required_signatures.is_empty())
            .map(|component| IndefiniteUnit {
                unit: format!("{}:{}", package.name, component.id),
                package: package.name.clone(),
                component: component.id.clone(),
                signatures: component.signatures.clone(),
                required_signatures: component.required_signatures.clone(),
                mixins: component.mixins.clone(),
                reexported_modules: component.reexported_modules.clone(),
            })
            .collect()
    }

    pub fn instantiations_from_package(package: &CabalPackage) -> Vec<ExpectedInstantiation> {
        package
            .components
            .iter()
            .flat_map(|component| {
                instantiations_from_mixins(
                    &format!("{}:{}", package.name, component.id),
                    &component.mixins,
                )
            })
            .collect()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExpectedOutputs {
    pub component_graph_drv: bool,
    pub module_graph_drv: bool,
    pub backpack_graph_drv: bool,
}
