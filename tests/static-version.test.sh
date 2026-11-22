#!/usr/bin/env bash
# Runs deploy.yml's real "Sync artifact" script with a fake `aws`: a build with
# a `version` file gets an explicit JSON copy after the sync (which skips a
# same-size file on a rollback), any other build gets none.
#
#   bash tests/static-version.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/static-version-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$*" in "s3api head-object"*) exit "$FAKE_HEAD" ;; esac
EOF
chmod +x "$TMP/bin/aws"

STEP="Sync artifact to the environment website bucket"
awk -v step="$STEP" '
  index($0, "- name: " step) { found = 1; next }
  found && !inrun && /^[[:space:]]*run: \|[[:space:]]*$/ { inrun = 1; match($0, /^[[:space:]]*/); base = RLENGTH; next }
  inrun { if ($0 ~ /^[[:space:]]*$/) { print ""; next }
          match($0, /^[[:space:]]*/); if (RLENGTH <= base) exit
          print substr($0, base + 3) }
' "$ROOT/.github/workflows/deploy.yml" > "$TMP/step.sh"
[ -s "$TMP/step.sh" ] || { echo "FAIL could not extract the step"; exit 1; }
# A static build has no client/ prefix.
# shellcheck disable=SC2016 # a literal ${{ in the extracted script
sed -i.bak 's/\${{ steps.layout.outputs.prefix }}//g' "$TMP/step.sh"

failed=0
check() { if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi; }
deploy() { # <exit code of head-object>
  : > "$TMP/log"
  env PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/log" FAKE_HEAD="$1" ARTIFACT_BUCKET=art \
    COMMIT_SHA=abc PROJECT_ID=p ENV=prod ENVS=dev,prod bash "$TMP/step.sh" > /dev/null
}
line() { grep -nF -- "$1" "$TMP/log" | head -n1 | cut -d: -f1; }
COPY="s3 cp s3://art/builds/abc/version s3://p-prod-website/version"

deploy 0
check "reads the file of this build" grep -qF -- "--key builds/abc/version" "$TMP/log"
check "copies it" grep -qF -- "$COPY" "$TMP/log"
check "as uncached JSON" grep -qF -- "--content-type application/json --cache-control no-store --metadata-directive REPLACE" "$TMP/log"
check "after the sync" test "$(line 's3 sync')" -lt "$(line "$COPY")"
deploy 255
check "a build without the file: no copy, no failure" test "$(grep -cF -- "$COPY" "$TMP/log")" = 0
exit "$failed"
