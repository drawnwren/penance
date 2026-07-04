use std::collections::BTreeMap;

pub fn normalize_flags(flags: BTreeMap<String, bool>) -> BTreeMap<String, bool> {
    flags
        .into_iter()
        .map(|(name, enabled)| (normalize_flag_name(&name), enabled))
        .collect()
}

fn normalize_flag_name(name: &str) -> String {
    name.trim().to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_are_sorted_and_normalized() {
        let flags = BTreeMap::from([
            ("Pkg:Use-Thing".to_string(), true),
            ("pkg:debug".to_string(), false),
        ]);
        let keys = normalize_flags(flags).into_keys().collect::<Vec<_>>();
        assert_eq!(keys, vec!["pkg:debug", "pkg:use-thing"]);
    }
}
