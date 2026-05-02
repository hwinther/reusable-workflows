# `_format-output` tests

Fixture-based tests for `.github/actions/_format-output/scripts/format.sh`.

## Run

```bash
bash scripts/format.test.sh           # all cases
bash scripts/format.test.sh ts        # only cases whose name contains "ts"
```

CI runs the same script via `.github/workflows/validate-version.yml`. Work dirs are staged under `.test-work/` (gitignored) so paths are accessible to native-Windows binaries on MSYS — `mktemp -d`'s default `/tmp` is an MSYS-internal mount that `jq.exe` can't read.

## Add a case

Each case is a directory under `cases/<name>/`:

| File | Required? | Purpose |
|---|---|---|
| `env.sh` | yes | Sourced before `format.sh` runs. Must set `FORMAT`. May set `ERROR_HEADER`, `WARNING_HEADER`, `SUCCESS_MESSAGE`, `MAX_WARNINGS_INLINE`, `PATH_STRIP`. |
| `errors` | optional | Pre-extracted error lines. Auto-mapped to `ERRORS_FILE` if present. |
| `warnings` | optional | Pre-extracted warning lines. Auto-mapped to `WARNINGS_FILE`. |
| `eslint.json` | optional | ESLint `--format json` report. Auto-mapped to `ERRORS_FILE` for `FORMAT=eslint-json` cases. |
| `expected.md` | yes | Diffed against the markdown `format.sh` writes to `OUT_MD`. |
| `expected.stdout` | optional | Diffed against captured GitHub annotations (the `::error::`/`::warning::` lines). |
| `expected.outputs` | optional | Diffed against captured `$GITHUB_OUTPUT` contents (`error_count=…`, `warning_count=…`, `failed=…`). |

## Adding a new format

1. Add the regex/parsing branch to `format.sh` (and add the new `format` value to the `case` statement plus the `emit_annotation` switch).
2. Add cases under `cases/<format>-<scenario>/` with realistic input lines and the expected outputs.
3. Run `bash scripts/format.test.sh` to verify.
