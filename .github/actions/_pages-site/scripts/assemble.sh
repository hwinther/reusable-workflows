#!/usr/bin/env bash
# Assembles a GitHub Pages site from layers and carries forward what is already published.
#
# Pages replaces the whole site on every deploy. So that one workflow can publish badges and
# another HTML reports, every deploy writes site-manifest.json at the site root, listing the files
# of each layer:
#   {"schemaVersion": 1, "repository": "...", "updatedAt": "...",
#    "layers": {"badges": ["tests-unit.svg", ...], "docs": ["index.html", "css/site.css"], ".": [...]}}
# A layer this run provides replaces that layer completely. A layer it does not provide is fetched
# file by file from the live site (BASE_URL + its manifest). Badges merge per file instead: the
# published ones are fetched and this run's SVGs are laid on top, so the quality summary badges
# and a nightly badge from another workflow live side by side.
#
# Environment:
#   SITE            output directory (created)
#   LAYERS_FILE     file with one `<source-dir>=<target>` per line; target `.` is the site root.
#                   The root goes first, then the rest in order, so a later layer wins on a clash.
#                   Target `badges` merges the directory's SVGs into the badges layer instead.
#                   May be empty or missing.
#   BADGES_DIRS     directories of new SVGs for the badges layer, one per line, later wins (optional)
#   BASE_URL        URL of the live site, without trailing slash (optional; file:// works too)
#   CARRY_FORWARD   `true` to carry forward missing layers and published badges
#   REPO            owner/repo, for the manifest and the generated index page
set -euo pipefail

: "${SITE:?}"
LAYERS_FILE="${LAYERS_FILE:-}"
BADGES_DIRS="${BADGES_DIRS:-}"
BASE_URL="${BASE_URL%/}"
CARRY_FORWARD="${CARRY_FORWARD:-true}"
REPO="${REPO:-}"

mkdir -p "$SITE"
SITE=$(cd "$SITE" && pwd)
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pages-site.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

target_re='^(\.|[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*)$'
badge_re='^[a-z0-9][a-z0-9-]*\.svg$'
manifest="$WORK/manifest.json"
echo '{}' > "$manifest"

# Relative file path inside a layer: no absolute paths, no `..`, no backslashes or control chars.
safe_file() {
  local f="$1"
  [[ -n "$f" && "$f" != /* && "$f" != *\\* && "$f" != *$'\n'* ]] || return 1
  [[ "/$f/" != */../* && "/$f/" != */./* ]] || return 1
}

record_layer() { # target, dir: list the files of dir under the target key
  local target="$1" dir="$2"
  (cd "$dir" && find . -type f ! -name site-manifest.json -printf '%P\n' | LC_ALL=C sort) \
    | jq -R . | jq -s --arg t "$target" --slurpfile m "$manifest" '$m[0] + {($t): .}' > "$WORK/m.tmp"
  mv "$WORK/m.tmp" "$manifest"
}

layer_path() { # target -> directory in the site
  if [ "$1" = "." ]; then echo "$SITE"; else echo "$SITE/$1"; fi
}

fetch() { # url, dest
  mkdir -p "$(dirname "$2")"
  curl -fsSL --retry 2 -o "$2" "$1"
}

# Published manifest
live="$WORK/live.json"
echo '{}' > "$live"
if [ "$CARRY_FORWARD" = "true" ] && [ -n "$BASE_URL" ]; then
  if curl -fsSL --retry 2 -o "$WORK/live-raw.json" "$BASE_URL/site-manifest.json" \
      && jq -e '.schemaVersion == 1 and (.layers | type == "object")' "$WORK/live-raw.json" > /dev/null; then
    jq '.layers' "$WORK/live-raw.json" > "$live"
    echo "Published layers: $(jq -r 'keys | join(", ")' "$live")"
  else
    echo "No site-manifest.json at $BASE_URL; nothing to carry forward."
  fi
fi

# Layers of this run, root first so a sub-path layer lands on top of it.
provided="$WORK/provided"
: > "$provided"
if [ -n "$LAYERS_FILE" ] && [ -f "$LAYERS_FILE" ]; then
  grep -v '^[[:space:]]*$' "$LAYERS_FILE" | awk -F= '{ print ($NF == "." ? 0 : 1) "\t" $0 }' \
    | sort -s -k1,1n | cut -f2- > "$WORK/layers"
  while IFS= read -r line; do
    src="${line%=*}"
    target="${line##*=}"
    target="${target%/}"
    [ -n "$target" ] || target="."
    if [[ ! "$target" =~ $target_re ]] || [ "$target" = "site-manifest.json" ]; then
      echo "::error::Invalid site path '$target' (relative, no '..')."
      exit 1
    fi
    if [ ! -d "$src" ]; then
      echo "::error::Layer source '$src' for '$target' is not a directory."
      exit 1
    fi
    if [ "$target" = "badges" ]; then
      BADGES_DIRS="${BADGES_DIRS}"$'\n'"$src"
      continue
    fi
    dest=$(layer_path "$target")
    mkdir -p "$dest"
    cp -R "$src/." "$dest/"
    record_layer "$target" "$src"
    echo "$target" >> "$provided"
    echo "Layer $target: $(find "$src" -type f | wc -l) files from $src"
  done < "$WORK/layers"
fi

# Badges: published ones first, this run's on top.
badges="$WORK/badges"
mkdir -p "$badges"
if [ "$CARRY_FORWARD" = "true" ] && [ -n "$BASE_URL" ]; then
  jq -r '.badges[]? // empty' "$live" | while IFS= read -r name; do
    if [[ "$name" =~ $badge_re ]]; then
      fetch "$BASE_URL/badges/$name" "$badges/$name" || echo "::warning::Could not carry forward badge $name."
    fi
  done
fi
while IFS= read -r dir; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  find "$dir" -maxdepth 1 -type f -name '*.svg' | while IFS= read -r f; do
    name=$(basename "$f")
    if [[ "$name" =~ $badge_re ]]; then
      cp "$f" "$badges/$name"
    else
      echo "::warning::Skipping badge $name (badge names are lowercase <name>.svg)."
    fi
  done
done <<< "$BADGES_DIRS"
if [ -n "$(ls -A "$badges")" ]; then
  mkdir -p "$SITE/badges"
  cp "$badges"/*.svg "$SITE/badges/"
  record_layer badges "$badges"
fi

# Carry forward the layers this run did not provide.
if [ "$CARRY_FORWARD" = "true" ] && [ -n "$BASE_URL" ]; then
  jq -r 'keys[] | select(. != "badges")' "$live" | while IFS= read -r target; do
    grep -qxF -- "$target" "$provided" && continue
    if [[ ! "$target" =~ $target_re ]]; then
      echo "::warning::Ignoring published layer with invalid path '$target'."
      continue
    fi
    dest=$(layer_path "$target")
    kept="$WORK/kept-$(echo "$target" | tr '/.' '__')"
    mkdir -p "$kept"
    count=0
    while IFS= read -r f; do
      safe_file "$f" || { echo "::warning::Skipping unsafe path '$f' in layer '$target'."; continue; }
      # A file a provided layer already wrote wins.
      [ -e "$dest/$f" ] && continue
      url_path=$(jq -rn --arg p "$f" '$p | split("/") | map(@uri) | join("/")')
      prefix=""
      [ "$target" = "." ] || prefix="$target/"
      if fetch "$BASE_URL/$prefix$url_path" "$kept/$f"; then
        count=$((count + 1))
      else
        echo "::warning::Could not carry forward $prefix$f."
      fi
    done < <(jq -r --arg t "$target" '.[$t][]? // empty' "$live")
    if [ -n "$(find "$kept" -type f -print -quit)" ]; then
      mkdir -p "$dest"
      cp -R "$kept/." "$dest/"
      record_layer "$target" "$kept"
    fi
    echo "Carried forward layer $target: $count files"
  done
fi

# Index page when no layer brought one.
if [ ! -f "$SITE/index.html" ]; then
  {
    echo '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
    echo "<title>${REPO:-Site}</title>"
    echo '<style>body{font:14px system-ui,sans-serif;margin:2rem auto;max-width:60rem;padding:0 1rem}td{padding:.4rem .8rem;vertical-align:middle}code{font-size:12px;word-break:break-all}</style>'
    echo "<h1>${REPO:-Site}</h1>"
    layers=$(jq -r 'keys[] | select(. != "badges" and . != ".")' "$manifest")
    if [ -n "$layers" ]; then
      echo '<h2>Contents</h2><ul>'
      while IFS= read -r t; do echo "<li><a href=\"${t}/\">${t}/</a></li>"; done <<< "$layers"
      echo '</ul>'
    fi
    if jq -e '.badges | length > 0' "$manifest" > /dev/null 2>&1; then
      echo '<h2>Badges</h2><table>'
      url="${BASE_URL:-https://<pages-url>}"
      jq -r '.badges[]' "$manifest" | while IFS= read -r name; do
        echo "<tr><td><img src=\"badges/${name}\" alt=\"${name%.svg}\"></td><td><code>![${name%.svg}](${url}/badges/${name})</code></td></tr>"
      done
      echo '</table>'
    fi
  } > "$SITE/index.html"
fi

jq -n --arg repo "$REPO" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile m "$manifest" \
  '{schemaVersion: 1, repository: $repo, updatedAt: $at, layers: $m[0]}' > "$SITE/site-manifest.json"

echo "Site: $(find "$SITE" -type f | wc -l) files, layers: $(jq -r 'keys | join(", ")' "$manifest")"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Pages site"
    echo
    jq -r 'to_entries[] | "- `\(.key)`: \(.value | length) files"' "$manifest"
  } >> "$GITHUB_STEP_SUMMARY"
fi
