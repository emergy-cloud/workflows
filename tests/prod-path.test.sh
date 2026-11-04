#!/usr/bin/env bash
# Runs the real `run:` scripts of the two steps that implement the contract
# v10 prod path (HQ D15) with a fake `gh`, and checks which Deploy runs they
# dispatch for each event: build.yml "Dispatch Deploy for this event" and
# deploy.yml "Request prod promotion (needs approval)". The scripts read only
# environment variables (no ${{ }} inside), so the step's env: block is
# reproduced here and GitHub is replaced by the FAKE_* answers below.
#
#   bash tests/prod-path.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/prod-path-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
LOG="$TMP/dispatches.log"
BUILD_STEP="Dispatch Deploy for this event"
PROMOTE_STEP="Request prod promotion (needs approval)"
passed=0
failed=0

# A fake gh: answers the reads from FAKE_* variables, records the dispatches.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || exit 2
shift
method=GET path="" fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H|--jq) shift 2 ;;
    -f) fields="$fields $2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
case "$method $path" in
  "POST "*/actions/workflows/deploy.yml/dispatches) echo "dispatch${fields}" >> "$FAKE_LOG"; exit "${FAKE_DISPATCH_EXIT:-0}" ;;
  "GET "*/environments/prod) [ "${FAKE_PROD_ENV:-present}" = present ] || exit 1; echo "${FAKE_RULES-required_reviewers}" ;;
  "GET "*/actions/workflows/deploy.yml/runs*) echo "${FAKE_EXISTING:-0}" ;;
  "GET "*/compare/*) echo "${FAKE_COMPARE:-ahead}" ;;
  *) echo "fake gh: unexpected call: $method $path" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/gh"

extract() { # <workflow file> <step name>: the step's run: block, unindented
  awk -v step="$2" '
    index($0, "- name: " step) { found = 1; next }
    found && !inrun && /^[[:space:]]*run: \|[[:space:]]*$/ { inrun = 1; match($0, /^[[:space:]]*/); base = RLENGTH; next }
    inrun { if ($0 ~ /^[[:space:]]*$/) { print ""; next }
            match($0, /^[[:space:]]*/); if (RLENGTH <= base) exit
            print substr($0, base + 3) }
  ' "$ROOT/.github/workflows/$1"
}
extract build.yml "$BUILD_STEP" > "$TMP/build-step.sh"
extract deploy.yml "$PROMOTE_STEP" > "$TMP/promote-step.sh"
for s in build-step promote-step; do
  [ -s "$TMP/$s.sh" ] || { echo "FAIL could not extract the $s script"; exit 1; }
  # shellcheck disable=SC2016 # a literal ${{ in the extracted script
  if grep -q '\${{' "$TMP/$s.sh"; then echo "FAIL the $s script uses \${{ }} (pass values through env: instead)"; exit 1; fi
done

run() { # <script> <expected dispatches, ;-separated, "" for none> <label> [VAR=value...]
  local script="$1" want="$2" label="$3" got status=0
  shift 3
  : > "$LOG"
  env PATH="$TMP/bin:$PATH" FAKE_LOG="$LOG" GH_TOKEN=x REPO=octo/app ENVS=dev,staging,prod \
    COMMIT_SHA="$SHA" EVENT_NAME=push REF_NAME=feature/x BASE_REF="" DEPLOY_ALL=false SELECTED_ENVS="" \
    RUN_REF=refs/heads/main "$@" bash "$TMP/$script.sh" > "$TMP/out" 2>&1 || status=$?
  got="$(tr '\n' ';' < "$LOG" | sed 's/;$//')"
  if [ "$status" = 0 ] && [ "$got" = "$want" ]; then
    passed=$((passed + 1)); echo "ok   $label"
  else
    failed=$((failed + 1)); echo "FAIL $label: exit $status, dispatched '$got', expected '$want'"
    sed 's/^/       /' "$TMP/out"
  fi
}
says() { # <label> <text>: the last run printed <text>
  if grep -qF -- "$2" "$TMP/out"; then passed=$((passed + 1)); echo "ok   $1"; else failed=$((failed + 1)); echo "FAIL $1: no '$2' in the output"; fi
}
d() { echo "dispatch ref=$1 inputs[environment]=$2 inputs[sha]=$SHA"; }

# ---- build.yml: the event map --------------------------------------------------
run build-step "$(d feature/x dev)" "push to a branch deploys dev"
run build-step "" "push to a branch without dev enabled deploys nothing" ENVS=staging,prod
says "  ... and says dev is not enabled" "dev is not an enabled environment"
run build-step "$(d main staging)" "push to main deploys staging, not prod" REF_NAME=main
run build-step "$(d main prod)" "push to main without staging requests prod (protected)" REF_NAME=main ENVS=dev,prod
run build-step "" "push to main without staging, prod without reviewers: nothing" REF_NAME=main ENVS=dev,prod FAKE_RULES=branch_policy
says "  ... with a warning naming the missing rule" "has no required reviewers"
run build-step "" "push to main without staging, no prod environment: nothing" REF_NAME=main ENVS=dev,prod FAKE_PROD_ENV=missing
says "  ... with a warning" "cannot read the prod environment"
run build-step "" "push to main without staging or prod: nothing" REF_NAME=main ENVS=dev
run build-step "" "push to main, prod run for the sha already there: no second request" REF_NAME=main ENVS=dev,prod FAKE_EXISTING=1
run build-step "" "pull request to main deploys nothing" EVENT_NAME=pull_request REF_NAME=7/merge BASE_REF=main
run build-step "$(d main dev);$(d main staging);$(d main prod)" "manual build deploy_all deploys every enabled env" EVENT_NAME=workflow_dispatch REF_NAME=main DEPLOY_ALL=true
run build-step "$(d main prod)" "manual build deploy_environments=prod deploys prod (its job still waits for approval)" EVENT_NAME=workflow_dispatch REF_NAME=main SELECTED_ENVS=prod
run build-step "" "manual build without inputs deploys nothing" EVENT_NAME=workflow_dispatch REF_NAME=main

# ---- deploy.yml: the promotion after a staging deploy ------------------------------
run promote-step "$(d main prod)" "staging deploy of a main commit requests prod with the same sha"
run promote-step "$(d main prod)" "  ... also when the sha is main's head (identical)" FAKE_COMPARE=identical
run promote-step "" "staging deploy dispatched from a branch: no promotion" RUN_REF=refs/heads/feature/x
run promote-step "" "staging deploy of a sha not on main: no promotion" FAKE_COMPARE=diverged
run promote-step "" "staging deploy of a sha ahead of main: no promotion" FAKE_COMPARE=behind
run promote-step "" "prod not enabled: no promotion" ENVS=dev,staging
run promote-step "" "prod without required reviewers: no promotion" FAKE_RULES=""
run promote-step "" "a short sha is never promoted" COMMIT_SHA=0123456
run promote-step "" "prod run for the sha already queued or done: no second request" FAKE_EXISTING=2
run promote-step "$(d main prod)" "a failed dispatch does not fail the staging deploy" FAKE_DISPATCH_EXIT=1
says "  ... and is reported as an error" "::error title=Prod promotion not requested::"

echo "prod path tests: ${passed} passed, ${failed} failed"
(( failed == 0 ))
