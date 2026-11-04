#!/usr/bin/env bash
# The load-bearing strings of the emergy.cloud workflow contract, and the
# guard against self-calling logic files. The platform dispatches these
# workflows and parses their run/job names; an edit that breaks one of these
# fails here before it reaches a project.
#
#   scripts/contract-check.sh [ROOT]   # ROOT: a checkout of this repository (default: this one)
#
# 1. Every logic file under .github/workflows (all but lint.yml) is a real
#    reusable workflow: a workflow_call trigger, its own runs-on, no job or
#    step that calls a workflow of this repository (emergy-cloud/workflows/...
#    or ./.github/workflows/...), no other run-time dependency on this
#    repository (vendored copies must stand alone). Commit d372cff once
#    replaced the logic with stubs calling themselves; this is the guard.
# 2. The contract strings of the four logic files, the v10 prod path included.
# 3. Every stub under stubs/<stack>/ carries its marker on line 1 and calls
#    the logic file of the same name at the version that marker states, which
#    is also the logic's version; stubs carry no logic of their own.
# tests/contract-check.test.sh runs this check on broken copies of the tree.
#
# The needles below are literal ${{ }} / ${VAR} strings, never expanded:
# shellcheck disable=SC2016
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
W=.github/workflows
FILES="build deploy update-infrastructure delete-infrastructure"
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
has_in() {   # <path> <needle>
  if grep -qF -- "$2" "$1"; then ok "${1#"$W"/}: $2"; else bad "${1#"$W"/}: missing $2"; fi
}
lacks_in() { # <path> <needle>
  if grep -qF -- "$2" "$1"; then bad "${1#"$W"/}: must not contain $2"; else ok "${1#"$W"/}: no $2"; fi
}
has()   { has_in "$W/$1" "$2"; }
lacks() { lacks_in "$W/$1" "$2"; }
# A `uses:` key of a job or a step (comment lines never match) that calls
# into this repository, by name or by a path in the calling repository.
CALLS_WORKFLOW='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?(emergy-cloud/workflows/|\./\.github/workflows/)'
# Any other non-comment mention of this repository: a checkout of it, a
# script fetched from it. A vendored copy would still depend on it.
NAMES_THIS_REPO='^[^#]*emergy-cloud/workflows'

# ---- 1. logic files are reusable workflows, never stubs ----------------------
for path in "$W"/*.yml "$W"/*.yaml; do
  [[ -e "$path" ]] || continue
  f="${path#"$W"/}"
  [[ "$f" == lint.yml ]] && continue
  if grep -qE '^[[:space:]]+workflow_call:|^on:[[:space:]]*\[?[[:space:]]*workflow_call' "$path"; then
    ok "$f: workflow_call trigger"
  else
    bad "$f: no workflow_call trigger (a logic file must be a reusable workflow)"
  fi
  if grep -qE '^[[:space:]]+runs-on:' "$path"; then
    ok "$f: runs-on"
  else
    bad "$f: no runs-on (a logic file runs its own steps; is this a stub?)"
  fi
  if hits="$(grep -nE "$CALLS_WORKFLOW" "$path")"; then
    bad "$f: calls a workflow (self-calling logic): $(echo "$hits" | tr '\n' ' ')"
  else
    ok "$f: calls no workflow"
  fi
  if hits="$(grep -nE "$NAMES_THIS_REPO" "$path")"; then
    bad "$f: depends on emergy-cloud/workflows at run time: $(echo "$hits" | tr '\n' ' ')"
  else
    ok "$f: no run-time dependency on this repository"
  fi
done

# ---- 2. contract strings of the four logic files ------------------------------
missing=0
for f in $FILES; do
  [[ -f "$W/$f.yml" ]] || { bad "$f.yml: missing"; missing=1; }
done
(( missing == 0 )) || { echo "contract: FAILED"; exit 1; }
V="$(sed -n 's/^# emergy.cloud workflow contract: astro v\([0-9]*\) (shared logic)$/\1/p' "$W/build.yml" | head -1)"
[[ -n "$V" ]] || { echo "FAIL build.yml: no contract marker on line 1"; exit 1; }
for f in $FILES; do
  if [[ "$(head -1 "$W/$f.yml")" == "# emergy.cloud workflow contract: astro v${V} (shared logic)" ]]; then
    ok "$f.yml: marker v${V}"
  else
    bad "$f.yml: marker is not v${V}"
  fi
  has "$f.yml" "  workflow_call:"
  lacks "$f.yml" "github.event.inputs"
  lacks "$f.yml" "workflow_dispatch:"
done
# environments appear only through the envs input / ENVS variable fallback
for f in build deploy update-infrastructure; do has "$f.yml" "\${{ inputs.envs || vars.ENVS || 'dev,staging,prod' }}"; done
# build: the deploy dispatch + its inputs, the worker bundle
has build.yml "      deploy_all:"
has build.yml "      deploy_environments:"
has build.yml "IFS=',' read -ra TARGETS <<< \"\${SELECTED_ENVS}\""
has build.yml "inputs[environment]"
has build.yml "inputs[sha]"
has build.yml "workflows/deploy.yml/dispatches"
has build.yml '.scripts["package:worker"]'
has build.yml "run package:worker"
has build.yml "aws s3 cp ./worker.zip"
has build.yml "vars.NODE_VERSION || '24'"
# build: the v10 event map (D15): branch -> dev, main -> staging (or the
# guarded prod request without staging), pull request -> build only
has build.yml "TARGETS=(dev)"
has build.yml "if enabled staging; then TARGETS=(staging); else PROMOTE=true; fi"
has build.yml 'request_prod "${COMMIT_SHA}"'
lacks build.yml "TARGETS=(prod)"
has build.yml "if: github.event_name != 'pull_request'"
# deploy: parsed names + inputs, the artifact key, the worker update
has deploy.yml "      environment:"
has deploy.yml "      sha:"
has deploy.yml 'name: Deploy ${{ inputs.environment }} from sha ${{ inputs.sha }}'
has deploy.yml 'environment: ${{ inputs.environment }}'
has deploy.yml '--key "builds/${COMMIT_SHA}/worker.zip"'
has deploy.yml 'FUNCTION_NAME="${PROJECT_ID}-worker"'
has deploy.yml '--function-name "${FUNCTION_NAME}"'
has deploy.yml "ResourceConflictException"
has deploy.yml "aws lambda wait function-updated-v2"
has deploy.yml "for ATTEMPT in 1 2 3 4 5 6"
# deploy: the promotion runs only after a staging deploy of a commit on main
has deploy.yml "if: inputs.environment == 'staging'"
has deploy.yml '"${RUN_REF}" != "refs/heads/main"'
has deploy.yml 'compare/${COMMIT_SHA}...main'
has deploy.yml 'request_prod "${COMMIT_SHA}"'
# the prod promotion guard: one block, identical in build.yml and deploy.yml
guard() { sed -n '/--- prod promotion guard (keep identical/,/--- end prod promotion guard ---/p' "$W/$1"; }
for f in build.yml deploy.yml; do
  g="$(guard "$f")"
  for needle in 'environments/prod' '",required_reviewers,"' 'Deploy prod @ ${sha}' '-f ref=main -f "inputs[environment]=prod" -f "inputs[sha]=${sha}"'; do
    if grep -qF -- "$needle" <<< "$g"; then ok "$f guard: $needle"; else bad "$f guard: missing $needle"; fi
  done
done
if [[ -n "$(guard build.yml)" && "$(guard build.yml)" == "$(guard deploy.yml)" ]]; then
  ok "prod promotion guard identical in build.yml and deploy.yml"
else
  bad "prod promotion guard: build.yml and deploy.yml differ (keep the two copies identical)"
fi
# infrastructure: prod-targeting jobs run under the prod environment
PROD_ENV="environment: \${{ contains(format(',{0},', inputs.envs || vars.ENVS || 'dev,staging,prod'), ',prod,') && 'prod' || '' }}"
has update-infrastructure.yml "$PROD_ENV"
has delete-infrastructure.yml "$PROD_ENV"
has delete-infrastructure.yml "      envs:"
has update-infrastructure.yml "vars.NODE_VERSION || '24'"
has update-infrastructure.yml "TF_VAR_envs:"
has delete-infrastructure.yml "      confirm:"
has delete-infrastructure.yml "inputs.confirm == 'confirm'"
# job ids
for pair in build:build deploy:deploy update-infrastructure:update delete-infrastructure:delete; do
  f="${pair%%:*}"; j="${pair##*:}"
  if grep -qE "^  ${j}:" "$W/$f.yml"; then ok "$f.yml: job id ${j}"; else bad "$f.yml: job id ${j} missing"; fi
done
# no runtime default older than the fleet's node
for f in build update-infrastructure; do
  if grep -qE "\|\|\s*'2[02]'" "$W/$f.yml"; then bad "$f.yml: stale NODE_VERSION default"; fi
done

# ---- 3. stubs call the logic at the version their marker states ---------------
stacks=0
for dir in stubs/*/; do
  [[ -d "$dir" ]] || continue
  stack="$(basename "$dir")"
  stacks=$((stacks + 1))
  for f in $FILES; do
    s="stubs/$stack/$f.yml"
    if [[ ! -f "$s" ]]; then bad "$s: missing"; continue; fi
    n="$(sed -n "1s/^# emergy.cloud workflow contract: ${stack} v\([0-9][0-9]*\)$/\1/p" "$s")"
    if [[ -z "$n" ]]; then bad "$s: line 1 is not '# emergy.cloud workflow contract: ${stack} v<N>'"; continue; fi
    if [[ "$n" == "$V" ]]; then ok "$s: marker v${n} = logic v${V}"; else bad "$s: marker v${n} but the logic is v${V}"; fi
    want="uses: emergy-cloud/workflows/.github/workflows/$f.yml@v${n}"
    calls="$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$s" | sed 's/^[[:space:]]*//' || true)"
    if [[ "$calls" == "$want" ]]; then
      ok "$s: calls $want"
    else
      bad "$s: calls '$(echo "$calls" | tr '\n' ' ')' instead of '$want' (the version its marker states)"
    fi
    has_in "$s" "secrets: inherit"
    lacks_in "$s" "runs-on:"
    lacks_in "$s" "steps:"
    lacks_in "$s" "github.event.inputs"
  done
  b="stubs/$stack/build.yml"; d="stubs/$stack/deploy.yml"
  u="stubs/$stack/update-infrastructure.yml"; x="stubs/$stack/delete-infrastructure.yml"
  [[ -f "$b" && -f "$d" && -f "$u" && -f "$x" ]] || continue
  for s in "$b" "$d" "$u"; do has_in "$s" "envs: \${{ vars.ENVS || 'dev,staging,prod' }}"; done
  has_in "$x" "envs: \${{ vars.ENVS || 'dev,staging,prod' }}"
  if grep -qE '^  build:$' "$b"; then ok "$b: job id build"; else bad "$b: job id build missing"; fi
  if grep -qE '^  deploy:$' "$d"; then ok "$d: job id deploy"; else bad "$d: job id deploy missing"; fi
  if grep -qE '^  update:$' "$u"; then ok "$u: job id update"; else bad "$u: job id update missing"; fi
  if grep -qE '^  delete:$' "$x"; then ok "$x: job id delete"; else bad "$x: job id delete missing"; fi
  has_in "$b" 'deploy_all: ${{ inputs.deploy_all == true }}'
  has_in "$b" "deploy_environments: \${{ inputs.deploy_environments || '' }}"
  has_in "$b" "branches: [ \"**\" ]"
  has_in "$b" "actions: write"
  has_in "$b" "id-token: write"
  has_in "$d" 'run-name: Deploy ${{ inputs.environment }} @ ${{ inputs.sha }}'
  has_in "$d" 'name: Deploy ${{ inputs.environment }} from sha ${{ inputs.sha }}'
  has_in "$d" 'environment: ${{ inputs.environment }}'
  has_in "$d" 'sha: ${{ inputs.sha }}'
  has_in "$d" 'group: deploy-${{ inputs.environment }}'
  has_in "$d" "actions: write"
  has_in "$u" "workflow_dispatch: {}"
  has_in "$u" "infrastructure/**"
  has_in "$u" "deployments: write"
  has_in "$x" "inputs.confirm == 'confirm'"
  has_in "$x" 'confirm: ${{ inputs.confirm }}'
done
(( stacks > 0 )) || bad "stubs/: no stub set (stubs/<stack>/*.yml)"

if (( fail == 0 )); then
  echo "contract v${V}: all checks passed"
else
  echo "contract v${V}: FAILED"
  exit 1
fi
