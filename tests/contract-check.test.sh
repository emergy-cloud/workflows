#!/usr/bin/env bash
# Proves scripts/contract-check.sh accepts this tree and rejects each breakage
# it guards against. Every case runs the check on a scratch copy of
# .github/ and stubs/ with one file broken; the real tree is never modified.
#
#   bash tests/contract-check.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHECK="$ROOT/scripts/contract-check.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/contract-check-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
W=.github/workflows
passed=0
failed=0

fresh() { # <case name>: a scratch copy of the tree the check reads
  mkdir -p "$TMP/$1"
  cp -R "$ROOT/.github" "$ROOT/stubs" "$TMP/$1/"
  echo "$TMP/$1"
}
expect_pass() { # <label> <root>
  local out
  if out="$(bash "$CHECK" "$2" 2>&1)"; then
    passed=$((passed + 1)); echo "ok   $1"
  else
    failed=$((failed + 1)); echo "FAIL $1: the check failed on a valid tree"
    grep '^FAIL' <<< "$out" | sed 's/^/       /'
  fi
}
expect_fail() { # <label> <root> <fragment of an expected FAIL line>...
  local label="$1" dir="$2" out needle
  shift 2
  if out="$(bash "$CHECK" "$dir" 2>&1)"; then
    failed=$((failed + 1)); echo "FAIL $label: the check passed, it must fail"
    return 0
  fi
  for needle in "$@"; do
    if ! grep -qF -- "$needle" <<< "$out"; then
      failed=$((failed + 1)); echo "FAIL $label: no output line with '$needle'"
      grep '^FAIL' <<< "$out" | sed 's/^/       /'
      return 0
    fi
  done
  passed=$((passed + 1)); echo "ok   $label"
}

# 1. the real tree passes
expect_pass "real tree passes" "$ROOT"

# 2. d372cff: build.yml became a reusable workflow whose job calls itself
d="$(fresh self-calling)"
cp "$HERE/fixtures/self-calling-build.yml" "$d/$W/build.yml"
expect_fail "self-calling build.yml (tests/fixtures/self-calling-build.yml) fails" "$d" \
  "FAIL build.yml: no runs-on" \
  "FAIL build.yml: calls a workflow (self-calling logic)"

# 3. a stub copied over a logic file: no workflow_call trigger either
d="$(fresh stub-as-logic)"
cp "$ROOT/stubs/astro/deploy.yml" "$d/$W/deploy.yml"
expect_fail "a stub copied into .github/workflows/deploy.yml fails" "$d" \
  "FAIL deploy.yml: no workflow_call trigger" \
  "FAIL deploy.yml: no runs-on" \
  "FAIL deploy.yml: calls a workflow (self-calling logic)"

# 4. a logic file whose job calls a workflow by local path
d="$(fresh local-call)"
cat >> "$d/$W/update-infrastructure.yml" <<'EOF'

  nested:
    uses: ./.github/workflows/build.yml
EOF
expect_fail "a job calling ./.github/workflows/build.yml fails" "$d" \
  "FAIL update-infrastructure.yml: calls a workflow (self-calling logic)"

# 5. a run-time dependency on this repository (a vendored copy would break)
d="$(fresh hidden-dependency)"
cat >> "$d/$W/delete-infrastructure.yml" <<'EOF'

  fetch:
    runs-on: ubuntu-latest
    steps:
      - run: curl -fsSL https://raw.githubusercontent.com/emergy-cloud/workflows/v10/scripts/x.sh | bash
EOF
expect_fail "a script fetched from emergy-cloud/workflows fails" "$d" \
  "FAIL delete-infrastructure.yml: depends on emergy-cloud/workflows at run time"

# 6. a stub that calls another version than its marker states
d="$(fresh stub-version)"
sed 's#/build.yml@v[0-9][0-9]*$#/build.yml@v9#' "$ROOT/stubs/astro/build.yml" > "$d/stubs/astro/build.yml"
expect_fail "stubs/astro/build.yml calling @v9 under its marker fails" "$d" \
  "FAIL stubs/astro/build.yml: calls 'uses: emergy-cloud/workflows/.github/workflows/build.yml@v9 '"

# 7. stubs one major ahead of the logic
d="$(fresh stub-marker)"
for f in "$d"/stubs/astro/*.yml; do
  sed -e '1s/ v[0-9][0-9]*$/ v99/' -e 's#\.yml@v[0-9][0-9]*$#.yml@v99#' "$f" > "$f.new" && mv "$f.new" "$f"
done
expect_fail "stubs at v99 with the logic at another version fail" "$d" \
  "FAIL stubs/astro/deploy.yml: marker v99 but the logic is"

# 8. the two copies of the prod promotion guard drifted apart
d="$(fresh guard-drift)"
sed 's/no second request/a second request/' "$ROOT/$W/deploy.yml" > "$d/$W/deploy.yml"
expect_fail "build.yml and deploy.yml guards that differ fail" "$d" \
  "FAIL prod promotion guard: build.yml and deploy.yml differ"

# 9. a push to main that deploys prod directly (the v9 event map)
d="$(fresh v9-event-map)"
sed 's/if enabled staging; then TARGETS=(staging); else PROMOTE=true; fi/TARGETS=(prod)/' "$ROOT/$W/build.yml" > "$d/$W/build.yml"
expect_fail "a push to main targeting prod fails" "$d" \
  "FAIL build.yml: must not contain TARGETS=(prod)"

echo "contract-check tests: ${passed} passed, ${failed} failed"
(( failed == 0 ))
