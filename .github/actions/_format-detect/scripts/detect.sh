#!/usr/bin/env bash
# Finds what format-and-create-pr.yml (mode: format / eslint-fix) should run in the repository
# checked out in the current directory. Only tracked files count (git ls-files), so build output,
# node_modules and the like never match.
#
#   solutions     .NET solutions for jb cleanupcode: every tracked *.slnx. Old *.sln files are not
#                 picked up on their own (they are often legacy or tooling solutions that don't
#                 restore on Linux); list them under `solutions:` in .github/format.yml.
#   prettier_dirs directories whose package.json depends on prettier, minus those inside another
#                 such directory (a workspace root formats its packages).
#   eslint_dirs   directories whose package.json depends on eslint and that hold an eslint.config.*
#                 (flat config), minus those inside another such directory.
#   install_dirs  where to run `npm ci` for those directories: the nearest directory at or above
#                 each with a package-lock.json, once each.
#   ruff          true when the repository configures Ruff (ruff.toml, .ruff.toml, or [tool.ruff] in
#                 a pyproject.toml).
#   gofmt         true when the repository has a go.mod.
#   excludes      the `exclude:` paths from .github/format.yml, for the formatter steps to skip.
#
# Optional .github/format.yml (read with yq, which GitHub's Ubuntu runners have):
#   exclude:          # repository paths (directories or files) never formatted
#     - src/legacy
#   solutions:        # replaces the *.slnx detection
#     - src/Tools.sln
#   cleanupcode: false   # turn a formatter off (also: prettier, eslint, ruff, gofmt)
#
# Inputs (environment): MODE (format | eslint-fix), CONFIG (default .github/format.yml).
# Writes each value to $GITHUB_OUTPUT (lists one path per line) and a summary to stdout.

set -euo pipefail

MODE="${MODE:-format}"
CONFIG="${CONFIG:-.github/format.yml}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

config_get() { # config_get <yq expression>; empty when there is no config
  [ -f "$CONFIG" ] || return 0
  if ! command -v yq > /dev/null 2>&1; then
    echo "::error file=$CONFIG::$CONFIG exists but yq is not installed to read it" >&2
    exit 1
  fi
  yq -r "$1 // \"\"" "$CONFIG"
}

enabled() { # enabled <formatter>: false only when the config says false
  [ "$(config_get ".$1")" != "false" ]
}

mapfile -t excludes < <(config_get '.exclude[]?' | sed -e 's|^\./||' -e 's|/*$||' | grep -v '^$' || true)

excluded() { # excluded <path>: the path is an excluded path or lies under one
  local p="${1#./}" e
  for e in "${excludes[@]+"${excludes[@]}"}"; do
    if [ "$p" = "$e" ] || [[ "$p" == "$e/"* ]]; then return 0; fi
  done
  return 1
}

# Keeps the directories that aren't inside another one in the list ("." contains everything).
outermost() {
  local -a dirs=("$@") kept=()
  local d o inside
  for d in "${dirs[@]+"${dirs[@]}"}"; do
    inside=false
    for o in "${dirs[@]}"; do
      [ "$o" = "$d" ] && continue
      if [ "$o" = "." ] || [[ "$d" == "$o/"* ]]; then inside=true; break; fi
    done
    $inside || kept+=("$d")
  done
  printf '%s\n' "${kept[@]+"${kept[@]}"}"
}

depends_on() { # depends_on <package.json> <package>
  jq -e --arg p "$2" '(.dependencies // {}) + (.devDependencies // {}) | has($p)' "$1" > /dev/null 2>&1
}

lock_dir() { # lock_dir <dir>: nearest directory at or above with a tracked package-lock.json
  local d="$1"
  while :; do
    if [ -n "$(git ls-files -- "$d/package-lock.json")" ]; then echo "$d"; return 0; fi
    [ "$d" = "." ] && return 1
    d="$(dirname "$d")"
  done
}

package_dirs_with() { # package_dirs_with <package> [require eslint config]
  local f d
  while IFS= read -r f; do
    d="$(dirname "$f")"
    excluded "$d" && continue
    depends_on "$f" "$1" || continue
    if [ "${2:-}" = "eslint-config" ] &&
       [ -z "$(git ls-files -- "$d/eslint.config.js" "$d/eslint.config.mjs" "$d/eslint.config.cjs" "$d/eslint.config.ts" "$d/eslint.config.mts")" ]; then
      continue
    fi
    echo "$d"
  done < <(git ls-files -- 'package.json' '**/package.json')
}

solutions=() prettier_dirs=() eslint_dirs=() ruff=false gofmt=false

if [ "$MODE" = "format" ]; then
  if enabled cleanupcode; then
    mapfile -t configured < <(config_get '.solutions[]?' | grep -v '^$' || true)
    if [ "${#configured[@]}" -gt 0 ]; then
      solutions=("${configured[@]}")
    else
      while IFS= read -r s; do
        excluded "$s" || excluded "$(dirname "$s")" || solutions+=("$s")
      done < <(git ls-files -- '*.slnx')
    fi
  fi
  if enabled prettier; then
    mapfile -t found < <(package_dirs_with prettier)
    mapfile -t prettier_dirs < <(outermost "${found[@]+"${found[@]}"}" | grep -v '^$' || true)
  fi
  if enabled ruff; then
    if [ -n "$(git ls-files -- 'ruff.toml' '**/ruff.toml' '.ruff.toml' '**/.ruff.toml')" ]; then
      ruff=true
    else
      while IFS= read -r p; do
        if grep -q '^\[tool\.ruff' "$p"; then ruff=true; break; fi
      done < <(git ls-files -- 'pyproject.toml' '**/pyproject.toml')
    fi
  fi
  if enabled gofmt && [ -n "$(git ls-files -- 'go.mod' '**/go.mod')" ]; then
    gofmt=true
  fi
elif [ "$MODE" = "eslint-fix" ]; then
  if enabled eslint; then
    mapfile -t found < <(package_dirs_with eslint eslint-config)
    mapfile -t eslint_dirs < <(outermost "${found[@]+"${found[@]}"}" | grep -v '^$' || true)
  fi
else
  echo "::error::Unknown MODE '$MODE' (format or eslint-fix)" >&2
  exit 1
fi

install_dirs=()
with_lock() { # with_lock <dirs...>: prints the dirs that have a lock file, records where to install
  local d l
  for d in "$@"; do
    if l="$(lock_dir "$d")"; then
      echo "$d"
      printf '%s\n' "$l" >> "$install_list"
    else
      echo "::warning file=$d/package.json::No package-lock.json at or above $d; skipped (npm ci needs one)" >&2
    fi
  done
}
install_list="$(mktemp)"
mapfile -t prettier_dirs < <(with_lock "${prettier_dirs[@]+"${prettier_dirs[@]}"}")
mapfile -t eslint_dirs < <(with_lock "${eslint_dirs[@]+"${eslint_dirs[@]}"}")
mapfile -t install_dirs < <(awk '!seen[$0]++' "$install_list")
rm -f "$install_list"

emit_list() { # emit_list <name> <items...>
  local name="$1"; shift
  {
    echo "$name<<__FORMAT_DETECT__"
    for i in "$@"; do [ -n "$i" ] && echo "$i"; done
    echo "__FORMAT_DETECT__"
  } >> "$OUT"
}

emit_list solutions "${solutions[@]+"${solutions[@]}"}"
emit_list prettier_dirs "${prettier_dirs[@]+"${prettier_dirs[@]}"}"
emit_list eslint_dirs "${eslint_dirs[@]+"${eslint_dirs[@]}"}"
emit_list install_dirs "${install_dirs[@]+"${install_dirs[@]}"}"
emit_list excludes "${excludes[@]+"${excludes[@]}"}"
{
  echo "ruff=$ruff"
  echo "gofmt=$gofmt"
  if [ "${#solutions[@]}" -gt 0 ] || [ "${#prettier_dirs[@]}" -gt 0 ] || [ "${#eslint_dirs[@]}" -gt 0 ] ||
     [ "$ruff" = true ] || [ "$gofmt" = true ]; then
    echo "any=true"
  else
    echo "any=false"
  fi
} >> "$OUT"

echo "Mode: $MODE"
echo "cleanupcode: ${solutions[*]:-(none)}"
echo "prettier:    ${prettier_dirs[*]:-(none)}"
echo "eslint:      ${eslint_dirs[*]:-(none)}"
echo "npm ci in:   ${install_dirs[*]:-(none)}"
echo "ruff:        $ruff"
echo "gofmt:       $gofmt"
echo "exclude:     ${excludes[*]:-(none)}"
