use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndefiniteUnit {
    pub unit: String,
    pub package: String,
    pub component: String,
    pub signatures: Vec<String>,
    pub required_signatures: Vec<String>,
    pub mixins: Vec<String>,
    pub reexported_modules: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExpectedInstantiation {
    pub unit: String,
    pub holes: BTreeMap<String, String>,
}

pub fn instantiations_from_mixins(unit: &str, mixins: &[String]) -> Vec<ExpectedInstantiation> {
    mixins
        .iter()
        .filter_map(|mixin| holes_from_mixin(mixin))
        .filter(|holes| !holes.is_empty())
        .map(|holes| ExpectedInstantiation {
            unit: unit.to_string(),
            holes,
        })
        .collect()
}

fn holes_from_mixin(mixin: &str) -> Option<BTreeMap<String, String>> {
    let (_, contents) = mixin.split_once('(')?;
    let contents = contents.strip_suffix(')').unwrap_or(contents).trim();

    let mut holes = BTreeMap::new();
    for entry in split_top_level_commas(contents) {
        if entry.starts_with("hiding ") {
            continue;
        }

        if let Some((hole, provider)) = entry.split_once('=') {
            holes.insert(hole.trim().to_string(), provider.trim().to_string());
            continue;
        }

        if let Some((provider, hole)) = entry.split_once(" as ") {
            holes.insert(hole.trim().to_string(), provider.trim().to_string());
        }
    }

    Some(holes)
}

fn split_top_level_commas(value: &str) -> Vec<&str> {
    let mut items = Vec::new();
    let mut start = 0;
    let mut depth = 0i32;

    for (idx, ch) in value.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' if depth == 0 => {
                let item = value[start..idx].trim();
                if !item.is_empty() {
                    items.push(item);
                }
                start = idx + 1;
            }
            _ => {}
        }
    }

    let item = value[start..].trim();
    if !item.is_empty() {
        items.push(item);
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_holes_from_as_mixins() {
        let instantiations = instantiations_from_mixins(
            "abstract:lib",
            &["impl (Data.IntMap as Data.MyAbstractMap)".to_string()],
        );

        assert_eq!(instantiations[0].holes["Data.MyAbstractMap"], "Data.IntMap");
    }

    #[test]
    fn extracts_holes_from_equals_mixins() {
        let instantiations = instantiations_from_mixins(
            "abstract:lib",
            &["abstract (Data.MyAbstractMap = containers:Data.IntMap)".to_string()],
        );

        assert_eq!(
            instantiations[0].holes["Data.MyAbstractMap"],
            "containers:Data.IntMap"
        );
    }
}
