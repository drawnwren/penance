use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CabalProject {
    pub packages: Vec<String>,
    pub source_repos: Vec<SourceRepo>,
}

pub type SourceRepo = BTreeMap<String, String>;

#[derive(Debug, thiserror::Error)]
pub enum CabalProjectError {
    #[error("cabal.project line {line}: unsupported cabal.project construct `{construct}`")]
    Unsupported { line: usize, construct: String },
    #[error("cabal.project line {line}: expected `key: value`, got `{text}`")]
    MalformedField { line: usize, text: String },
}

#[derive(Clone, Debug)]
struct LogicalLine {
    line: usize,
    indent: usize,
    text: String,
}

pub fn parse_cabal_project(text: &str) -> Result<CabalProject, CabalProjectError> {
    let lines = logical_lines(text);
    let mut packages = Vec::new();
    let mut source_repos = Vec::new();
    let mut i = 0;

    while i < lines.len() {
        let line = &lines[i];
        if line.indent != 0 {
            return Err(CabalProjectError::MalformedField {
                line: line.line,
                text: line.text.clone(),
            });
        }

        if line.text == "source-repository-package" {
            let (repo, next) = parse_source_repo(&lines, i + 1)?;
            source_repos.push(repo);
            i = next;
            continue;
        }

        let (field, first_value) =
            split_field(line).ok_or_else(|| CabalProjectError::MalformedField {
                line: line.line,
                text: line.text.clone(),
            })?;
        let (value, next) = collect_continuation_value(&lines, i + 1, line.indent, first_value);

        match field {
            "packages" | "optional-packages" => packages.extend(split_words(&value)),
            "constraints" | "allow-newer" | "allow-older" | "with-compiler" | "index-state"
            | "repository" | "remote-repo-cache" | "jobs" => {}
            _ => {
                return Err(CabalProjectError::Unsupported {
                    line: line.line,
                    construct: field.to_string(),
                })
            }
        }

        i = next;
    }

    packages.sort();
    packages.dedup();
    source_repos.sort();

    Ok(CabalProject {
        packages,
        source_repos,
    })
}

fn parse_source_repo(
    lines: &[LogicalLine],
    mut i: usize,
) -> Result<(SourceRepo, usize), CabalProjectError> {
    let mut repo = SourceRepo::new();

    while i < lines.len() {
        let line = &lines[i];
        if line.indent == 0 {
            break;
        }

        let (field, first_value) =
            split_field(line).ok_or_else(|| CabalProjectError::MalformedField {
                line: line.line,
                text: line.text.clone(),
            })?;
        let (value, next) = collect_continuation_value(lines, i + 1, line.indent, first_value);
        repo.insert(field.to_string(), value);
        i = next;
    }

    Ok((repo, i))
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

fn split_field(line: &LogicalLine) -> Option<(&str, &str)> {
    let (field, value) = line.text.split_once(':')?;
    Some((field.trim(), value.trim()))
}

fn split_words(value: &str) -> Vec<String> {
    value
        .split_whitespace()
        .filter(|word| !word.is_empty())
        .map(|word| word.trim_matches(',').to_string())
        .filter(|word| !word.is_empty())
        .collect()
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
    fn parses_packages_and_source_repos() {
        let project = parse_cabal_project(
            r#"
packages:
  ./a
  ./b

source-repository-package
  type: git
  location: https://example.invalid/pkg.git
  tag: abc123
"#,
        )
        .unwrap();

        assert_eq!(project.packages, vec!["./a", "./b"]);
        assert_eq!(project.source_repos[0]["type"], "git");
        assert_eq!(project.source_repos[0]["tag"], "abc123");
    }
}
