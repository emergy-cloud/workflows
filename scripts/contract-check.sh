#!/usr/bin/env bash
# The load-bearing strings of the emergy.cloud workflow contract. The platform
# dispatches these workflows and parses their run/job names; an edit that
# breaks one of these fails here before it reaches a project. (The same
# assertions used to live in www.emergy.cloud's workflow-templates test, when
# the files were copied into every repository; the stubs there now pin only
# their own shape.)
set -euo pipefail
cd "$(dirname "$0")/.."
W=.github/workflows
fail=0
has() {   # <file> <needle>
  if grep -qF -- "$2" "$W/$1"; then echo "ok   $1: $2"; else echo "FAIL $1: missing $2"; fail=1; fi
}
lacks() { # <file> <needle>
  if grep -qF -- "$2" "$W/$1"; then echo "FAIL $1: must not contain $2"; fail=1; else echo "ok   $1: no $2"; fi
}
V="$(sed -n 's/^# emergy.cloud workflow contract: astro v\([0-9]*\).*/\1/p' "$W/build.yml" | head -1)"
[[ -n "$V" ]] || { echo "FAIL build.yml: no contract marker on line 1"; exit 1; }
for f in build deploy update-infrastructure delete-infrastructure; do
  [[ "$(head -1 "$W/$f.yml")" == "# emergy.cloud workflow contract: astro v${V} (shared logic)" ]] && echo "ok   $f.yml: marker v${V}" || { echo "FAIL $f.yml: marker is not v${V}"; fail=1; }
  has "$f.yml" "  workflow_call:"
  lacks "$f.yml" "github.event.inputs"
  lacks "$f.yml" "workflow_dispatch:"
done
# environments appear only through the envs input / ENVS variable fallback
for f in build deploy update-infrastructure; do has "$f.yml" "\${{ inputs.envs || vars.ENVS || 'dev,staging,prod' }}"; done
# build: the deploy dispatch + its inputs, the dev/staging/prod event map, the worker bundle
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
# infrastructure
has update-infrastructure.yml "vars.NODE_VERSION || '24'"
has update-infrastructure.yml "TF_VAR_envs:"
has delete-infrastructure.yml "      confirm:"
has delete-infrastructure.yml "inputs.confirm == 'confirm'"
# job ids
for pair in build:build deploy:deploy update-infrastructure:update delete-infrastructure:delete; do
  f="${pair%%:*}"; j="${pair##*:}"
  grep -qE "^  ${j}:" "$W/$f.yml" && echo "ok   $f.yml: job id ${j}" || { echo "FAIL $f.yml: job id ${j} missing"; fail=1; }
done
# no runtime default older than the fleet's node
for f in build update-infrastructure; do
  if grep -qE "\|\|\s*'2[02]'" "$W/$f.yml"; then echo "FAIL $f.yml: stale NODE_VERSION default"; fail=1; fi
done
(( fail == 0 )) && echo "contract v${V}: all checks passed" || { echo "contract v${V}: FAILED"; exit 1; }
