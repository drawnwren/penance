use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CabalPackage {
    pub path: String,
    pub name: String,
    pub version: String,
    pub components: Vec<CabalComponent>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CabalComponent {
    pub id: String,
    pub kind: ComponentKind,
    pub name: Option<String>,
    pub provided_modules: Vec<String>,
    pub signatures: Vec<String>,
    pub required_signatures: Vec<String>,
    pub mixins: Vec<String>,
    pub reexported_modules: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ComponentKind {
    Library,
    Executable,
    TestSuite,
    Benchmark,
}

#[derive(Debug, thiserror::Error)]
pub enum CabalFileError {
    #[error("{path}: line {line}: unsupported Cabal stanza `{stanza}`")]
    UnsupportedStanza {
        path: String,
        line: usize,
        stanza: String,
    },
    #[error("{path}: line {line}: expected `key: value`, got `{text}`")]
    MalformedField {
        path: String,
        line: usize,
        text: String,
    },
    #[error("{path}: missing required top-level `{field}:` field")]
    MissingField { path: String, field: &'static str },
}

#[derive(Clone, Debug)]
struct LogicalLine {
    line: usize,
    indent: usize,
    text: String,
}

#[derive(Clone, Debug)]
struct StanzaHeader {
    kind: ComponentKind,
    name: Option<String>,
}

pub fn parse_cabal_file(path: &str, text: &str) -> Result<CabalPackage, CabalFileError> {
    let lines = logical_lines(text);
    let mut i = 0;
    let mut top_fields = BTreeMap::new();
    let mut components = Vec::new();

    while i < lines.len() {
        let line = &lines[i];
        if is_conditional_or_import_line(&line.text) {
            i += 1;
            continue;
        }

        if line.indent != 0 {
            return Err(CabalFileError::MalformedField {
                path: path.to_string(),
                line: line.line,
                text: line.text.clone(),
            });
        }

        if let Some(header) = parse_stanza_header(&line.text) {
            let (component, next) = parse_component(path, &lines, i + 1, header)?;
            components.push(component);
            i = next;
            continue;
        }

        if should_skip_top_level_stanza(&line.text) {
            i = skip_stanza(&lines, i);
            continue;
        }

        if looks_like_unsupported_stanza(&line.text) {
            return Err(CabalFileError::UnsupportedStanza {
                path: path.to_string(),
                line: line.line,
                stanza: line.text.clone(),
            });
        }

        let (field, first_value) =
            split_field(line).ok_or_else(|| CabalFileError::MalformedField {
                path: path.to_string(),
                line: line.line,
                text: line.text.clone(),
            })?;
        let (value, next) = collect_continuation_value(&lines, i + 1, line.indent, first_value);
        insert_or_append_field(&mut top_fields, field, value);
        i = next;
    }

    let name = top_fields
        .remove("name")
        .ok_or_else(|| CabalFileError::MissingField {
            path: path.to_string(),
            field: "name",
        })?;
    let version = top_fields
        .remove("version")
        .ok_or_else(|| CabalFileError::MissingField {
            path: path.to_string(),
            field: "version",
        })?;

    components.sort();

    Ok(CabalPackage {
        path: path.to_string(),
        name,
        version,
        components,
    })
}

fn parse_component(
    path: &str,
    lines: &[LogicalLine],
    mut i: usize,
    header: StanzaHeader,
) -> Result<(CabalComponent, usize), CabalFileError> {
    let mut fields = BTreeMap::new();

    while i < lines.len() {
        let line = &lines[i];
        if is_conditional_or_import_line(&line.text) {
            i += 1;
            continue;
        }

        if line.indent == 0 {
            break;
        }
        if parse_stanza_header(&line.text).is_some() || looks_like_unsupported_stanza(&line.text) {
            return Err(CabalFileError::UnsupportedStanza {
                path: path.to_string(),
                line: line.line,
                stanza: line.text.clone(),
            });
        }

        let (field, first_value) =
            split_field(line).ok_or_else(|| CabalFileError::MalformedField {
                path: path.to_string(),
                line: line.line,
                text: line.text.clone(),
            })?;
        let (value, next) = collect_continuation_value(lines, i + 1, line.indent, first_value);
        insert_or_append_field(&mut fields, field, value);
        i = next;
    }

    let mut provided_modules = Vec::new();
    provided_modules.extend(split_module_list(fields.get("exposed-modules")));
    provided_modules.extend(split_module_list(fields.get("other-modules")));
    provided_modules.extend(split_module_list(fields.get("generated-other-modules")));
    if matches!(
        header.kind,
        ComponentKind::Executable | ComponentKind::TestSuite | ComponentKind::Benchmark
    ) && fields.contains_key("main-is")
    {
        provided_modules.push("Main".to_string());
    }
    provided_modules.sort();
    provided_modules.dedup();

    let signatures = split_module_list(fields.get("signatures"));
    let required_signatures = signatures.clone();
    let mixins = split_top_level_list(fields.get("mixins"));
    let reexported_modules = split_top_level_list(fields.get("reexported-modules"));

    Ok((
        CabalComponent {
            id: component_id(&header),
            kind: header.kind,
            name: header.name,
            provided_modules,
            signatures,
            required_signatures,
            mixins,
            reexported_modules,
        },
        i,
    ))
}

fn parse_stanza_header(text: &str) -> Option<StanzaHeader> {
    let mut words = text.split_whitespace();
    let first = words.next()?.to_ascii_lowercase();
    let second = words.next();
    if words.next().is_some() {
        return None;
    }

    match (first.as_str(), second) {
        ("library", None) => Some(StanzaHeader {
            kind: ComponentKind::Library,
            name: None,
        }),
        ("library", Some(name)) => Some(StanzaHeader {
            kind: ComponentKind::Library,
            name: Some(name.to_string()),
        }),
        ("executable", Some(name)) => Some(StanzaHeader {
            kind: ComponentKind::Executable,
            name: Some(name.to_string()),
        }),
        ("test-suite", Some(name)) => Some(StanzaHeader {
            kind: ComponentKind::TestSuite,
            name: Some(name.to_string()),
        }),
        ("benchmark", Some(name)) => Some(StanzaHeader {
            kind: ComponentKind::Benchmark,
            name: Some(name.to_string()),
        }),
        _ => None,
    }
}

fn component_id(header: &StanzaHeader) -> String {
    match (&header.kind, &header.name) {
        (ComponentKind::Library, None) => "lib".to_string(),
        (ComponentKind::Library, Some(name)) => format!("lib:{name}"),
        (ComponentKind::Executable, Some(name)) => format!("exe:{name}"),
        (ComponentKind::TestSuite, Some(name)) => format!("test:{name}"),
        (ComponentKind::Benchmark, Some(name)) => format!("bench:{name}"),
        _ => "unknown".to_string(),
    }
}

fn looks_like_unsupported_stanza(text: &str) -> bool {
    let head = text
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(head.as_str(), "foreign-library")
}

fn should_skip_top_level_stanza(text: &str) -> bool {
    let head = text
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        head.as_str(),
        "flag" | "common" | "custom-setup" | "source-repository"
    )
}

fn skip_stanza(lines: &[LogicalLine], mut i: usize) -> usize {
    let base_indent = lines[i].indent;
    i += 1;
    while i < lines.len() && lines[i].indent > base_indent {
        i += 1;
    }
    i
}

fn is_conditional_or_import_line(text: &str) -> bool {
    let text = text.trim().to_ascii_lowercase();
    text.starts_with("if ")
        || text == "else"
        || text.starts_with("elif ")
        || text.starts_with("import ")
}

fn insert_or_append_field(fields: &mut BTreeMap<String, String>, field: &str, value: String) {
    fields
        .entry(field.to_ascii_lowercase())
        .and_modify(|existing| {
            if !existing.is_empty() && !value.is_empty() {
                existing.push('\n');
            }
            existing.push_str(&value);
        })
        .or_insert(value);
}

fn split_field(line: &LogicalLine) -> Option<(&str, &str)> {
    let (field, value) = line.text.split_once(':')?;
    Some((field.trim(), value.trim()))
}

fn collect_continuation_value(
    lines: &[LogicalLine],
    mut i: usize,
    field_indent: usize,
    first_value: &str,
) -> (String, usize) {
    let mut parts = Vec::new();
    if !first_value.trim().is_empty() {
        parts.push(first_value.trim().to_string());
    }

    while i < lines.len() && lines[i].indent > field_indent {
        parts.push(lines[i].text.trim().to_string());
        i += 1;
    }

    (parts.join("\n"), i)
}

fn split_module_list(value: Option<&String>) -> Vec<String> {
    split_top_level_list(value)
        .into_iter()
        .flat_map(|chunk| {
            chunk
                .split_whitespace()
                .map(|module| module.trim_matches(',').to_string())
                .collect::<Vec<_>>()
        })
        .filter(|module| !module.is_empty())
        .collect()
}

fn split_top_level_list(value: Option<&String>) -> Vec<String> {
    let Some(value) = value else {
        return Vec::new();
    };

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
                    items.push(item.to_string());
                }
                start = idx + 1;
            }
            _ => {}
        }
    }

    let item = value[start..].trim();
    if !item.is_empty() {
        items.push(item.to_string());
    }

    items.sort();
    items.dedup();
    items
}

fn logical_lines(text: &str) -> Vec<LogicalLine> {
    text.lines()
        .enumerate()
        .filter_map(|(idx, line)| {
            let line = strip_comment(line);
            if line.trim().is_empty() {
                return None;
            }

            let indent = line.chars().take_while(|ch| ch.is_whitespace()).count();
            Some(LogicalLine {
                line: idx + 1,
                indent,
                text: line.trim().to_string(),
            })
        })
        .collect()
}

fn strip_comment(line: &str) -> &str {
    match line.find("--") {
        Some(index) => &line[..index],
        None => line,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_backpack_fields() {
        let parsed = parse_cabal_file(
            "demo/demo.cabal",
            r#"
cabal-version: 3.8
name: demo
version: 0.1.0.0
build-type: Simple

library
  exposed-modules: Demo
  other-modules:
    Demo.Internal
  signatures:
    Data.MyAbstractMap
  mixins:
    impl (Data.IntMap as Data.MyAbstractMap),
    base hiding (Prelude)
  reexported-modules:
    Data.MyAbstractMap as Demo.Map
  build-depends: base
  default-language: Haskell2010
"#,
        )
        .unwrap();

        let component = &parsed.components[0];
        assert_eq!(component.id, "lib");
        assert_eq!(component.provided_modules, vec!["Demo", "Demo.Internal"]);
        assert_eq!(component.signatures, vec!["Data.MyAbstractMap"]);
        assert_eq!(
            component.mixins,
            vec![
                "base hiding (Prelude)",
                "impl (Data.IntMap as Data.MyAbstractMap)"
            ]
        );
        assert_eq!(
            component.reexported_modules,
            vec!["Data.MyAbstractMap as Demo.Map"]
        );
    }

    #[test]
    fn tolerates_conditionals_for_surface_discovery() {
        let parsed = parse_cabal_file(
            "demo/demo.cabal",
            r#"
name: demo
version: 0.1

flag dev
  default: False

common warnings
  ghc-options: -Wall

source-repository head
  type: git
  location: https://example.invalid/demo.git

library
  import: warnings
  exposed-modules: Demo
  if flag(dev)
    exposed-modules: Demo.Dev
  else
    other-modules: Demo.Release

library support
  exposed-modules: Demo.Support
"#,
        )
        .unwrap();

        assert_eq!(parsed.components[0].id, "lib");
        assert_eq!(
            parsed.components[0].provided_modules,
            vec!["Demo", "Demo.Dev", "Demo.Release"]
        );
        assert_eq!(parsed.components[1].id, "lib:support");
        assert_eq!(parsed.components[1].provided_modules, vec!["Demo.Support"]);
    }

    #[test]
    fn records_main_module_for_buildable_entrypoints() {
        let parsed = parse_cabal_file(
            "demo/demo.cabal",
            r#"
name: demo
version: 0.1

executable demo
  main-is: DemoMain.hs
  hs-source-dirs: app
"#,
        )
        .unwrap();

        assert_eq!(parsed.components[0].provided_modules, vec!["Main"]);
    }
}
