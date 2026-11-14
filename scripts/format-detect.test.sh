#!/usr/bin/env bash
# Tests for .github/actions/_format-detect/scripts/detect.sh.
#
# Each case builds a throwaway git repository, runs detect.sh in it and compares the GITHUB_OUTPUT
# it writes with the expected text. Cases that need a .github/format.yml are skipped when yq is not
# installed (GitHub's Ubuntu runners have it).
#
# Run: bash scripts/format-detect.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT="$REPO_ROOT/.github/actions/_format-detect/scripts/detect.sh"
# Under the repo, not /tmp, so native Windows jq on MSYS can read the files.
WORK_ROOT="$REPO_ROOT/.test-work/format-detect"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

pass=0 fail=0 skip=0

# new_repo <name>: an empty git repository to add files to; prints its path
new_repo() {
  local dir="$WORK_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config core.autocrlf false
  echo "$dir"
}

# put <repo> <path> [content]: writes and stages a file
put() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "${3:-}" > "$1/$2"
  git -C "$1" add -- "$2"
}

# check <name> <repo> <mode> <expected output>
check() {
  local name="$1" repo="$2" mode="$3" expected="$4" out actual
  out="$repo/.github-output"
  : > "$out"
  if ! (cd "$repo" && MODE="$mode" GITHUB_OUTPUT="$out" bash "$DETECT" > /dev/null 2> "$repo/.stderr"); then
    echo "FAIL $name: detect.sh exited non-zero"
    cat "$repo/.stderr"
    fail=$((fail + 1))
    return
  fi
  actual="$(tr -d '\r' < "$out")"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual")
    fail=$((fail + 1))
  fi
}

lists() { # lists <solutions> <prettier> <eslint> <install> <excludes> <ruff> <gofmt> <any>
  local name i=0
  for name in solutions prettier_dirs eslint_dirs install_dirs excludes; do
    i=$((i + 1))
    echo "$name<<__FORMAT_DETECT__"
    [ -n "${!i}" ] && printf '%s\n' "${!i}"
    echo "__FORMAT_DETECT__"
  done
  echo "ruff=$6"
  echo "gofmt=$7"
  echo "any=$8"
}

PRETTIER='{"devDependencies":{"prettier":"3.0.0"}}'
ESLINT='{"devDependencies":{"eslint":"10.0.0","prettier":"3.0.0"}}'

# .NET + frontend + e2e, like ClutterStock: the solution, both npm projects, each with its lock.
r="$(new_repo dotnet-node)"
put "$r" backend/App.slnx
put "$r" backend/tools/Old.sln
put "$r" frontend/package.json "$ESLINT"
put "$r" frontend/package-lock.json
put "$r" frontend/eslint.config.js
put "$r" e2e/package.json "$PRETTIER"
put "$r" e2e/package-lock.json
put "$r" scripts/badges/package.json '{"dependencies":{"left-pad":"1.0.0"}}'
check "dotnet + node: format" "$r" format \
  "$(lists "backend/App.slnx" $'e2e\nfrontend' "" $'e2e\nfrontend' "" false false true)"
check "dotnet + node: eslint-fix" "$r" eslint-fix \
  "$(lists "" "" "frontend" "frontend" "" false false true)"

# npm workspaces, like romslig: the root formats everything, installs once.
r="$(new_repo workspaces)"
put "$r" package.json "$ESLINT"
put "$r" package-lock.json
put "$r" eslint.config.mjs
put "$r" apps/web/package.json "$PRETTIER"
put "$r" apps/web/eslint.config.js
put "$r" packages/shared/package.json "$ESLINT"
check "workspaces: format" "$r" format "$(lists "" "." "" "." "" false false true)"
check "workspaces: eslint-fix" "$r" eslint-fix "$(lists "" "" "." "." "" false false true)"

# A workspace package whose root doesn't use prettier installs at the root's lock.
r="$(new_repo workspace-member)"
put "$r" package.json '{"workspaces":["packages/*"]}'
put "$r" package-lock.json
put "$r" packages/ui/package.json "$PRETTIER"
check "workspace member installs at the root" "$r" format "$(lists "" "packages/ui" "" "." "" false false true)"

# No lock file anywhere: skipped with a warning.
r="$(new_repo no-lock)"
put "$r" web/package.json "$PRETTIER"
check "no lock file: skipped" "$r" format "$(lists "" "" "" "" "" false false false)"

# eslint without a flat config doesn't count.
r="$(new_repo eslint-no-config)"
put "$r" package.json "$ESLINT"
put "$r" package-lock.json
check "eslint without flat config" "$r" eslint-fix "$(lists "" "" "" "" "" false false false)"

# Python: Ruff only when configured.
r="$(new_repo python)"
put "$r" tools/pyproject.toml $'[project]\nname = "x"'
put "$r" main.py
check "python without ruff config" "$r" format "$(lists "" "" "" "" "" false false false)"
put "$r" pyproject.toml $'[project]\nname = "y"\n\n[tool.ruff]\nline-length = 100'
check "pyproject with [tool.ruff]" "$r" format "$(lists "" "" "" "" "" true false true)"
r="$(new_repo ruff-toml)"
put "$r" src/ruff.toml 'line-length = 100'
check "ruff.toml" "$r" format "$(lists "" "" "" "" "" true false true)"

# Go.
r="$(new_repo go)"
put "$r" go.mod 'module example.test/x'
put "$r" main.go 'package main'
check "go.mod" "$r" format "$(lists "" "" "" "" "" false true true)"

# Untracked files don't count.
r="$(new_repo untracked)"
mkdir -p "$r/node_modules/x"
printf '%s\n' "$PRETTIER" > "$r/node_modules/x/package.json"
printf 'x\n' > "$r/App.slnx"
check "untracked files ignored" "$r" format "$(lists "" "" "" "" "" false false false)"

# .github/format.yml
if command -v yq > /dev/null 2>&1; then
  r="$(new_repo config)"
  put "$r" backend/App.slnx
  put "$r" legacy/Old.sln
  put "$r" frontend/package.json "$PRETTIER"
  put "$r" frontend/package-lock.json
  put "$r" docs/package.json "$PRETTIER"
  put "$r" docs/package-lock.json
  put "$r" go.mod 'module x'
  put "$r" .github/format.yml $'exclude:\n  - ./docs/\nsolutions:\n  - legacy/Old.sln\ngofmt: false'
  check "format.yml: exclude, solutions, gofmt off" "$r" format \
    "$(lists "legacy/Old.sln" "frontend" "" "frontend" "docs" false false true)"
  put "$r" .github/format.yml $'cleanupcode: false\nprettier: false'
  check "format.yml: formatters off" "$r" format "$(lists "" "" "" "" "" false true true)"
else
  echo "skip format.yml cases (no yq)"
  skip=$((skip + 2))
fi

rm -rf "$WORK_ROOT"
echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
