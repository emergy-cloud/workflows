#!/usr/bin/env bash
# Tests scripts/install.sh end to end on scratch target repositories: both
# modes write exactly their files (never ci.yml, claude.yml or anything else),
# pins and the ENVS fallback land where expected, vendored logic is the
# source byte for byte under its stamped header and names this repository
# only in comments, and bad input is refused before anything is written.
# With ACTIONLINT (path to the binary) or actionlint on PATH, the outputs of
# both modes are also linted, inside a git repository so that actionlint
# resolves the local ./.github/workflows/vendored-*.yml calls.
#
#   bash tests/install.test.sh
#
# The bash -c snippets below expand their own positional arguments:
# shellcheck disable=SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FILES="build deploy update-infrastructure delete-infrastructure"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
ACTIONLINT="${ACTIONLINT:-$(command -v actionlint || true)}"
passed=0
failed=0

check() { # <label> <command...>: one assertion
  local label="$1"; shift
  if "$@"; then passed=$((passed + 1)); echo "ok   $label"; else failed=$((failed + 1)); echo "FAIL $label"; fi
}
run_to() { # <output file> <install.sh args...>
  local out="$1"; shift
  bash "$INSTALL" "$@" > "$out" 2>&1
}
contains() { grep -qF -- "$2" "$1"; }
not_contains() { ! grep -qF -- "$2" "$1"; }
line1_is() { [ "$(head -1 "$1")" = "$2" ]; }
snapshot() { # <dir>: one line per file (path + checksum), .git excluded
  (cd "$1" && find . -path ./.git -prune -o -type f -print | sort | while read -r p; do echo "$p $(cksum < "$p")"; done)
}
changed() { # <before snapshot> <dir>: the paths added or modified since the snapshot
  diff <(echo "$1") <(snapshot "$2") | sed -n 's/^> \([^ ]*\) .*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//'
}
new_target() { # <name> [copy-an-old-build.yml]: a scratch repository with unrelated files
  local d="$TMP/$1"
  mkdir -p "$d/.github/workflows"
  printf 'name: CI\non: [push]\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ci\n' > "$d/.github/workflows/ci.yml"
  printf 'name: Claude\n' > "$d/.github/workflows/claude.yml"
  printf 'readme\n' > "$d/README.md"
  if [ "${2:-}" = old-build ]; then
    printf "# emergy.cloud workflow contract: astro v7\njobs:\n  build:\n    env:\n      ENVS: \${{ inputs.envs || vars.ENVS || 'dev,prod' }}\n" > "$d/.github/workflows/build.yml"
  fi
  echo "$d"
}
lint() { # <dir>: actionlint the files install.sh wrote, inside a git repository
  local d="$1" f files=()
  for f in "$d"/.github/workflows/{build,deploy,update-infrastructure,delete-infrastructure}.yml "$d"/.github/workflows/vendored-*.yml; do
    if [ -f "$f" ]; then files+=("${f#"$d"/}"); fi
  done
  (cd "$d" && { [ -d .git ] || git init -q .; } && "$ACTIONLINT" -no-color -oneline -shellcheck= "${files[@]}")
}

# ---- 1. ref mode, pinned, ENVS fallback taken from the current build.yml ----------
d="$(new_target ref-pinned old-build)"
before="$(snapshot "$d")"
out="$TMP/ref-pinned.out"
check "ref mode v10.0.0 succeeds" run_to "$out" --mode ref --ref v10.0.0 --target "$d"
check "ref mode writes exactly the 4 stubs" [ "$(changed "$before" "$d")" = "./.github/workflows/build.yml ./.github/workflows/delete-infrastructure.yml ./.github/workflows/deploy.yml ./.github/workflows/update-infrastructure.yml" ]
check "ref mode prints 4 wrote lines" [ "$(grep -c '^wrote ' "$out")" = 4 ]
check "ref mode reuses the target's ENVS fallback" contains "$out" "envs fallback: dev,prod (from the target's current build.yml)"
for f in $FILES; do
  s="$d/.github/workflows/$f.yml"
  check "ref $f.yml: marker v10 on line 1" line1_is "$s" "# emergy.cloud workflow contract: astro v10"
  check "ref $f.yml: calls @v10.0.0" contains "$s" "uses: emergy-cloud/workflows/.github/workflows/$f.yml@v10.0.0"
  check "ref $f.yml: fallback dev,prod" contains "$s" "vars.ENVS || 'dev,prod'"
  check "ref $f.yml: no full fallback left" not_contains "$s" "'dev,staging,prod'"
done
if [ -n "$ACTIONLINT" ]; then check "ref mode output passes actionlint" lint "$d"; fi

# ---- 2. ref mode, moving major, explicit envs normalized, empty target -------------
d="$TMP/ref-major"; mkdir -p "$d"
check "ref mode v10 on an empty target succeeds" run_to "$TMP/ref-major.out" --mode ref --ref v10 --envs "prod, dev,staging" --target "$d"
check "ref mode v10: stubs call @v10" contains "$d/.github/workflows/deploy.yml" "uses: emergy-cloud/workflows/.github/workflows/deploy.yml@v10"
check "ref mode v10: envs in contract order" contains "$d/.github/workflows/build.yml" "vars.ENVS || 'dev,staging,prod'"

d="$TMP/ref-pipe"; mkdir -p "$d"
check "output piped into head still writes all 4 stubs" bash -c '
  bash "$1" --mode ref --ref v10 --target "$2" | head -1 > /dev/null
  for f in build deploy update-infrastructure delete-infrastructure; do [ -f "$2/.github/workflows/$f.yml" ] || exit 1; done
' _ "$INSTALL" "$d"

# ---- 3. vendor mode from a revision name ----------------------------------------
d="$(new_target vendor old-build)"
before="$(snapshot "$d")"
out="$TMP/vendor.out"
check "vendor mode --ref HEAD succeeds" run_to "$out" --mode vendor --ref HEAD --envs dev,prod --target "$d"
check "vendor mode writes exactly 4 stubs + 4 vendored files" [ "$(changed "$before" "$d")" = "./.github/workflows/build.yml ./.github/workflows/delete-infrastructure.yml ./.github/workflows/deploy.yml ./.github/workflows/update-infrastructure.yml ./.github/workflows/vendored-build.yml ./.github/workflows/vendored-delete-infrastructure.yml ./.github/workflows/vendored-deploy.yml ./.github/workflows/vendored-update-infrastructure.yml" ]
check "vendor mode prints 8 wrote lines" [ "$(grep -c '^wrote ' "$out")" = 8 ]
for f in $FILES; do
  s="$d/.github/workflows/$f.yml"; v="$d/.github/workflows/vendored-$f.yml"
  check "vendor $f.yml: calls the local vendored copy" contains "$s" "uses: ./.github/workflows/vendored-$f.yml"
  check "vendored-$f.yml: stamped header" line1_is "$v" "# vendored from emergy-cloud/workflows@HEAD ($HEAD_SHA): do not edit, refresh with scripts/install.sh"
  check "vendored-$f.yml: the source logic byte for byte" cmp -s <(tail -n +2 "$v") <(git -C "$ROOT" show "$HEAD_SHA:.github/workflows/$f.yml")
done
check "vendor output names emergy-cloud/workflows only in comments" \
  bash -c '! grep -nE "^[^#]*emergy-cloud/workflows" "$1"/.github/workflows/*.yml' _ "$d"
check "vendor output has no checkout of another repository" \
  bash -c '! grep -nE "^[[:space:]]+repository:" "$1"/.github/workflows/vendored-*.yml' _ "$d"
if [ -n "$ACTIONLINT" ]; then check "vendor mode output passes actionlint" lint "$d"; fi

# ---- 4. vendor mode from a full sha, then back to ref mode on the same repo --------
d="$(new_target vendor-sha)"
check "vendor mode --ref <sha> succeeds" run_to "$TMP/vendor-sha.out" --mode vendor --ref "$HEAD_SHA" --target "$d"
check "vendor mode --ref <sha>: header carries the sha" contains "$d/.github/workflows/vendored-build.yml" "# vendored from emergy-cloud/workflows@$HEAD_SHA ($HEAD_SHA)"
check "vendor mode without --envs or build.yml: full fallback" contains "$d/.github/workflows/build.yml" "vars.ENVS || 'dev,staging,prod'"
check "switching to ref mode succeeds" run_to "$TMP/switch.out" --mode ref --ref v10 --target "$d"
check "switching to ref mode flags the vendored leftovers" contains "$TMP/switch.out" "note: .github/workflows/vendored-build.yml is left in place but no longer called"

# ---- 5. refusals leave the target untouched ------------------------------------
d="$(new_target refusals old-build)"
before="$(snapshot "$d")"
refused() { # <expected exit code> <install.sh args...>
  local want="$1" got=0; shift
  bash "$INSTALL" "$@" > "$TMP/refused.out" 2>&1 || got=$?
  [ "$got" = "$want" ] && [ -z "$(changed "$before" "$d")" ]
}
check "ref mode refuses a branch name (exit 2)" refused 2 --mode ref --ref main --target "$d"
check "ref mode refuses a major the stubs are not (exit 1)" refused 1 --mode ref --ref v9.0.0 --target "$d"
check "vendor mode refuses an unknown ref (exit 1)" refused 1 --mode vendor --ref no-such-ref-xyz --target "$d"
check "an unknown environment is refused (exit 1)" refused 1 --mode ref --ref v10 --envs dev,qa --target "$d"
check "a missing --target is refused (exit 2)" refused 2 --mode ref --ref v10
check "--from in vendor mode is refused (exit 2)" refused 2 --mode vendor --ref HEAD --from HEAD --target "$d"
root_before="$(snapshot "$ROOT/.github")"
check "this repository as the target is refused (exit 1)" bash -c '! bash "$1" --mode ref --ref v10 --target "$2" > /dev/null 2>&1' _ "$INSTALL" "$ROOT"
check "this repository's workflows are unchanged by the refusal" [ -z "$(changed "$root_before" "$ROOT/.github")" ]

[ -n "$ACTIONLINT" ] || echo "note: actionlint not found (set ACTIONLINT); outputs were not linted"
echo "install.sh tests: ${passed} passed, ${failed} failed"
(( failed == 0 ))
