#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: validate-surface-parity.sh PENANCE_OUT HASKELL_NIX_SURFACE_JSON CABAL_FILE OUT_DIR" >&2
  exit 2
fi

penance_out="$1"
haskell_nix_surface="$2"
cabal_file="$3"
out_dir="$4"
component_kinds="${PENANCE_SURFACE_COMPONENT_KINDS:-}"

mkdir -p "$out_dir"

if [[ -n "$component_kinds" ]]; then
  kind_filter_json="$(printf '%s\n' $component_kinds | jq -R . | jq -s .)"
else
  kind_filter_json="[]"
fi

filter_surface() {
  local path="$1"
  jq -S --argjson kinds "$kind_filter_json" '
    def keepKind:
      if ($kinds | length) == 0 then true
      else (.kind as $kind | $kinds | index($kind) != null)
      end;

    if ($kinds | length) == 0 then
      .
    else
      (.components | map(select(keepKind))) as $components
      | ($components | map(.package + "\u0000" + .component)) as $componentKeys
      | .components = $components
      | if has("modules") then
          .modules = (
            .modules
            | map(select((.package + "\u0000" + .component) as $key | $componentKeys | index($key) != null))
          )
        else
          .
        end
    end
  ' "$path" >"$path.filtered"
  mv "$path.filtered" "$path"
}

jq -S -n \
  --slurpfile packages "$penance_out/packages/package-graph.json" \
  --slurpfile modules "$penance_out/modules/module-graph.json" '
    {
      source: "penance",
      packages:
        [ $packages[0].packages[]
          | {name: .package, version}
        ] | sort_by(.name, .version),
      components:
        [ $packages[0].packages[] as $pkg
          | $pkg.components[]
          | {package: $pkg.package, component, kind}
        ] | sort_by(.package, .component, .kind),
      modules:
        [ $modules[0].modules[]
          | {package, component, module}
        ] | sort_by(.package, .component, .module)
    }
  ' >"$out_dir/penance.surface.json"
filter_surface "$out_dir/penance.surface.json"

jq -S '
  {
    source,
    packages: (.packages | sort_by(.name, .version)),
    components: (.components | sort_by(.package, .component, .kind))
  }
' "$haskell_nix_surface" >"$out_dir/haskell-nix.surface.json"
filter_surface "$out_dir/haskell-nix.surface.json"

perl - "$cabal_file" >"$out_dir/cabal.surface.json" <<'PERL'
use strict;
use warnings;

my ($path) = @ARGV;
open my $fh, '<', $path or die "cannot open $path: $!";

my $package = "";
my $version = "";
my @components;
my @modules;
my $current;
my $current_field = "";

sub trim {
  my ($value) = @_;
  $value =~ s/^\s+//;
  $value =~ s/\s+$//;
  return $value;
}

sub json_string {
  my ($value) = @_;
  $value =~ s/\\/\\\\/g;
  $value =~ s/"/\\"/g;
  $value =~ s/\n/\\n/g;
  $value =~ s/\r/\\r/g;
  $value =~ s/\t/\\t/g;
  return '"' . $value . '"';
}

sub words_from_field {
  my ($value) = @_;
  $value =~ s/,/ /g;
  return grep { $_ ne "" } map { trim($_) } split /\s+/, $value;
}

sub add_component {
  my ($component, $kind) = @_;
  push @components, {
    package => $package,
    component => $component,
    kind => $kind,
  };
}

sub add_modules {
  my ($component, @names) = @_;
  for my $name (@names) {
    next if $name eq "";
    push @modules, {
      package => $package,
      component => $component,
      module => $name,
    };
  }
}

while (my $line = <$fh>) {
  $line =~ s/--.*$//;
  next if $line =~ /^\s*$/;

  if ($line !~ /^\s/) {
    my $top = trim($line);
    $current_field = "";

    if ($top =~ /^name\s*:\s*(.+)$/i) {
      $package = trim($1);
      next;
    }
    if ($top =~ /^version\s*:\s*(.+)$/i) {
      $version = trim($1);
      next;
    }
    if ($top =~ /^library\s*$/i) {
      $current = { component => "lib", kind => "library" };
      add_component($current->{component}, $current->{kind});
      next;
    }
    if ($top =~ /^library\s+(.+)$/i) {
      $current = { component => "lib:" . trim($1), kind => "library" };
      add_component($current->{component}, $current->{kind});
      next;
    }
    if ($top =~ /^executable\s+(.+)$/i) {
      $current = { component => "exe:" . trim($1), kind => "executable" };
      add_component($current->{component}, $current->{kind});
      next;
    }
    if ($top =~ /^test-suite\s+(.+)$/i) {
      $current = { component => "test:" . trim($1), kind => "test-suite" };
      add_component($current->{component}, $current->{kind});
      next;
    }
    if ($top =~ /^benchmark\s+(.+)$/i) {
      $current = { component => "bench:" . trim($1), kind => "benchmark" };
      add_component($current->{component}, $current->{kind});
      next;
    }

    $current = undef;
    next;
  }

  next unless defined $current;
  my $field_line = trim($line);

  if ($field_line =~ /^([A-Za-z0-9-]+)\s*:\s*(.*)$/) {
    $current_field = lc($1);
    my $value = $2;

    if ($current_field eq "exposed-modules" || $current_field eq "other-modules" || $current_field eq "generated-other-modules") {
      add_modules($current->{component}, words_from_field($value));
    } elsif ($current_field eq "main-is") {
      add_modules($current->{component}, "Main");
    }
    next;
  }

  if ($current_field eq "exposed-modules" || $current_field eq "other-modules" || $current_field eq "generated-other-modules") {
    add_modules($current->{component}, words_from_field($field_line));
  }
}

@components = sort {
  $a->{package} cmp $b->{package}
    || $a->{component} cmp $b->{component}
    || $a->{kind} cmp $b->{kind}
} @components;
my %seen_components;
@components = grep {
  my $key = join "\0", $_->{package}, $_->{component}, $_->{kind};
  !$seen_components{$key}++;
} @components;

@modules = sort {
  $a->{package} cmp $b->{package}
    || $a->{component} cmp $b->{component}
    || $a->{module} cmp $b->{module}
} @modules;
my %seen_modules;
@modules = grep {
  my $key = join "\0", $_->{package}, $_->{component}, $_->{module};
  !$seen_modules{$key}++;
} @modules;

print "{\n";
print "  \"source\": \"cabal\",\n";
print "  \"packages\": [";
print "{\"name\":" . json_string($package) . ",\"version\":" . json_string($version) . "}";
print "],\n";
print "  \"components\": [";
for my $i (0 .. $#components) {
  print "," if $i > 0;
  my $entry = $components[$i];
  print "{\"package\":" . json_string($entry->{package})
    . ",\"component\":" . json_string($entry->{component})
    . ",\"kind\":" . json_string($entry->{kind})
    . "}";
}
print "],\n";
print "  \"modules\": [";
for my $i (0 .. $#modules) {
  print "," if $i > 0;
  my $entry = $modules[$i];
  print "{\"package\":" . json_string($entry->{package})
    . ",\"component\":" . json_string($entry->{component})
    . ",\"module\":" . json_string($entry->{module})
    . "}";
}
print "]\n";
print "}\n";
PERL

jq -S . "$out_dir/cabal.surface.json" >"$out_dir/cabal.surface.sorted.json"
mv "$out_dir/cabal.surface.sorted.json" "$out_dir/cabal.surface.json"
filter_surface "$out_dir/cabal.surface.json"

jq -S '{packages, components}' "$out_dir/penance.surface.json" >"$out_dir/penance.package-components.json"
jq -S '{packages, components: [.components[] | {package, component, kind}]}' "$out_dir/haskell-nix.surface.json" >"$out_dir/haskell-nix.package-components.json"
jq -S '{packages, components}' "$out_dir/cabal.surface.json" >"$out_dir/cabal.package-components.json"

diff -u "$out_dir/cabal.package-components.json" "$out_dir/penance.package-components.json"
diff -u "$out_dir/cabal.package-components.json" "$out_dir/haskell-nix.package-components.json"

jq -S '{packages, components, modules}' "$out_dir/penance.surface.json" >"$out_dir/penance.modules.json"
jq -S '{packages, components, modules}' "$out_dir/cabal.surface.json" >"$out_dir/cabal.modules.json"
diff -u "$out_dir/cabal.modules.json" "$out_dir/penance.modules.json"

jq -S -n \
  --slurpfile penance "$out_dir/penance.surface.json" \
  --slurpfile haskellNix "$out_dir/haskell-nix.surface.json" \
  --slurpfile cabal "$out_dir/cabal.surface.json" \
  --argjson kinds "$kind_filter_json" '
    {
      status: "ok",
      compared: {
        packageComponents: ["cabal", "penance", "haskell.nix"],
        modules: ["cabal", "penance"]
      },
      counts: {
        packages: ($penance[0].packages | length),
        components: ($penance[0].components | length),
        modules: ($penance[0].modules | length)
      },
      filter: {
        componentKinds: $kinds
      },
      surfaces: {
        penance: $penance[0],
        haskellNix: $haskellNix[0],
        cabal: $cabal[0]
      }
    }
  ' >"$out_dir/surface-parity.json"

printf 'validated surface parity: %s\n' "$out_dir/surface-parity.json"
