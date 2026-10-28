# emergy.cloud workflows

The CI/CD pipeline of every emergy.cloud project, as **reusable GitHub Actions
workflows** (`on: workflow_call`), plus the per-repository **stubs** that call
them and the command that installs both. This repository is public so a
project in any GitHub organization can call it; it holds no secrets and no
project data.

| Shared workflow | Called by the stub | Does |
|---|---|---|
| `.github/workflows/build.yml` | `build.yml` | build the commit, upload `builds/<sha>/` to the artifact bucket, dispatch Deploy for the environment the event targets |
| `.github/workflows/deploy.yml` | `deploy.yml` | promote one built artifact to one environment (static assets, SSR Lambda, worker, CloudFront invalidation); after staging, request the same artifact for prod (approval-gated) |
| `.github/workflows/update-infrastructure.yml` | `update-infrastructure.yml` | `terraform apply` + GitHub Deployments per enabled environment |
| `.github/workflows/delete-infrastructure.yml` | `delete-infrastructure.yml` | `terraform destroy`, gated on the typed `confirm` input |

Current contract: **v10** (`stubs/astro/`, marker `# emergy.cloud workflow contract: astro v10`).
Design: [spec](docs/specs/shared-ci-v10.md), [ADR 0001](docs/adr/0001-d15-prod-path-and-vendoring.md).
Rolling it out to a repository: [docs/adoption.md](docs/adoption.md).

## The prod path (contract v10, HQ decision D15)

| Event | Build does | Deploys |
|---|---|---|
| push to a branch other than `main` | build, upload | **dev** |
| push to `main` (a merge made on GitHub, or on Forgejo and delivered by the push mirror) | build, upload | **staging**; then prod is requested for the same sha (below) |
| push to `main`, `staging` not in ENVS | build, upload | prod requested directly (same guard) |
| pull request to `main` | build only (no AWS role, no upload) | nothing |
| manual Build (`deploy_all`, `deploy_environments`) | build, upload | the selected or all enabled environments, as before |
| manual Deploy (`environment`, `sha`) | - | that environment (prod still waits for its approval) |

**Promotion.** When a staging deploy succeeds, ran from `main` and its sha is on
`main`, the deploy logic dispatches Deploy `prod` with the **same sha**: the
same artifact, no rebuild. That run's job declares `environment: prod`, so
GitHub pauses it until a **required reviewer** of the `prod` environment
approves it (Actions run page, "Review deployments").

**Guard.** The promotion is requested only when `prod` is in ENVS **and** the
repository's `prod` environment has a `required_reviewers` protection rule
(read with the job token: `GET repos/{repo}/environments/prod`). Otherwise the
run shows a notice or warning saying why and nothing reaches prod, so a push
can never deploy prod without an approval. It is also skipped when a Deploy
prod run for the same sha is already queued, waiting, running or done.

**Prod-targeting jobs.** Deploy prod, the infrastructure apply (one apply
updates every environment) and the destroy run under `environment: prod`
when prod is enabled, so the same reviewers approve them.

### Approval setup (owner, once per repository, GitHub UI)

1. Repository **Settings > Environments > `prod`** (create it if the first prod
   deploy did not).
2. **Required reviewers**: tick it, add yourself (and anyone else who may ship).
   Leave **Prevent self-review** off while you are the only reviewer.
3. **Deployment branches and tags**: "Selected branches and tags", add `main`
   (promotions run on `main`; a prod deploy started from another branch is then
   refused).
4. Optional: untick **Allow administrators to bypass configured protection
   rules** for a strict gate.

Plan note: GitHub offers environment protection rules on public repositories
on every plan, but documents required reviewers on private repositories only
for GitHub Enterprise; verify each organization's plan. Where the rule cannot
be set, the guard skips and prod stays a manual deploy (platform button,
`dvk ship`, or a Deploy run on `main`). Variables set on the `prod` GitHub
environment override repository variables inside prod-environment jobs; keep
CI variables at repository level. A prod run waiting for approval holds the
`deploy-prod` concurrency group: GitHub keeps one newer pending run and
cancels older pending ones, so reject the requests you do not want.

## How a project uses it

Each project repository keeps a **thin stub** per workflow under
`.github/workflows/` (the same four file names) holding only what must live in
the repository: the triggers, `permissions`, `concurrency`, the
`workflow_dispatch` inputs and the `ENVS` fallback. The stub calls the logic:

```yaml
jobs:
  build:
    uses: emergy-cloud/workflows/.github/workflows/build.yml@v10
    with:
      envs: ${{ vars.ENVS || 'dev,staging,prod' }}
      deploy_all: ${{ inputs.deploy_all == true }}
      deploy_environments: ${{ inputs.deploy_environments || '' }}
    secrets: inherit
```

`vars.*` (`PROJECT_ID`, `ENVS`, the AWS role ARNs...) and `secrets.*` resolve
in the **calling** repository, and the OIDC token carries the caller's
identity, so nothing changes on the AWS side when a project moves from a full
copy of the workflow to a stub.

| Mode | The stubs call | For |
|---|---|---|
| **ref, auto** (default) | `emergy-cloud/workflows/...@v10`, the moving major | templates and repositories that take every compatible fix |
| **ref, pinned** | `...@v10.0.0` (or a full commit sha) | a repository that changes only when it bumps |
| **vendor** | `./.github/workflows/vendored-<file>.yml`, local copies of the logic | repositories that must not reference this one (orgs `upmatch-io`, `Store-AI-Group-Inc`, `delinecor`: HQ D4/D9) |

### Install and bump (`scripts/install.sh`)

One command writes the CI into a repository and is the same command that
bumps it later. It is offline: every file comes from this repository's git
objects (`git show <rev>:<path>`), so the output is reproducible from a sha.

```sh
# reference mode, following the moving major / pinned
scripts/install.sh --mode ref    --ref v10     --target /repos/www.boulot.ai
scripts/install.sh --mode ref    --ref v10.0.0 --target /repos/www.boulot.ai
# vendored mode (excluded orgs); --ref may be a tag, a branch or a sha
scripts/install.sh --mode vendor --ref v10.0.0 --target /repos/app.upmatch.io
# options: --envs dev,prod (ENVS fallback; default: the target's current
#          build.yml fallback, else dev,staging,prod), --stack astro,
#          --from <rev> (ref mode: read the stub templates from <rev>)
```

- **ref** writes the four stubs with `@<ref>`. The ref must be `vN`, `vN.N.N`
  or a full sha, and its major must match the stubs' contract. The stub
  templates come from `<ref>` when it exists in the clone, else from `HEAD`
  (said in the output).
- **vendor** writes the four stubs calling `./.github/workflows/vendored-<file>.yml`
  plus those four files: the logic at `<ref>` byte for byte under the header
  `# vendored from emergy-cloud/workflows@<ref> (<sha>): do not edit, refresh with scripts/install.sh`.
  It refuses output with a non-comment line naming `emergy-cloud/workflows`;
  the logic never checks out this repository nor fetches a script from it.
- It writes **only** those files (never `ci.yml`, `claude.yml` or anything
  else), prints each one, and refuses to write into a checkout of this
  repository (how d372cff happened). Bump = run it again with the new `--ref`;
  review `git diff`, commit.

The emergy.cloud platform serves the same stubs in reference mode from its
CI/CD reference (`curl -fsSL 'https://emergy.cloud/api/workflows.sh?envs=dev,prod' | sh`);
it syncs them from `stubs/astro/` here (`website/scripts/sync-workflow-stubs.mjs`
in www.emergy.cloud) and records the source sha.

## Versioning

- **`vX.Y.Z`** tags are immutable releases; **`vX`** is the moving major that
  points at the newest `vX.Y.Z`. The major is the contract version on line 1 of
  every stub (`astro v10` = `v10.*`).
- **Logic fix or compatible addition** (same inputs, job ids, names, triggers,
  stub shape): new `vX.Y.(Z+1)` (fix) or `vX.(Y+1).0` (addition), then move
  `vX` to it. Auto repositories pick it up on their next run, pinned ones when
  they bump.
- **Contract change** (a file name, job id, parsed run or job name, dispatch
  input, trigger or what an event deploys, a permission the stub must grant,
  the stub shape, the ENVS vocabulary): new major `v(X+1).0.0` + `v(X+1)` and
  new stubs. Repositories move by re-running `scripts/install.sh`.
- Never move a `vX.Y.Z` tag. `v9` stays frozen where it is (`v9.0.0`, below);
  to fix an old major after a newer one exists, branch `release/v9` from
  `v9.0.0`, fix, tag `v9.0.1`, move `v9`.

Tags are created by the owner on the canonical repository (Forgejo), never on
GitHub. Release commands for this change (run in a clone whose `origin` is
Forgejo, after the v10 pull request is merged):

```sh
git fetch origin --tags
# freeze v9 where it points today (d698d3ce01182853ef89a5857a1720d530098390)
git tag -a v9.0.0 'v9^{commit}' -m "emergy.cloud workflow contract v9.0.0"
# release v10 on the merged commit
git tag -a v10.0.0 origin/main -m "emergy.cloud workflow contract v10.0.0 (D15 prod path)"
git tag -a v10 origin/main -m "emergy.cloud workflow contract v10"
git push origin v9.0.0 v10.0.0 v10
```

A later fix: `git tag -a v10.0.1 <sha> -m "..." && git tag -fa v10 <sha> -m "emergy.cloud workflow contract v10"`,
then `git push origin v10.0.1 && git push -f origin v10`.

The Forgejo push mirror (sync on commit) forwards the tags to
`github.com/emergy-cloud/workflows`, where `uses:` resolves them. Check with
`git ls-remote --tags https://github.com/emergy-cloud/workflows`; if a tag is
missing, use the repository's Settings > Repository > Mirror settings >
Synchronize now on Forgejo.

## Guarantees the platform relies on (kept by `scripts/contract-check.sh`)

- file names, job ids (`build`, `deploy`, `update`, `delete`), the deploy run
  name `Deploy <env> @ <sha>` and job name `Deploy <env> from sha <sha>` (the
  webhook parses them);
- the dispatch inputs `deploy_all`, `deploy_environments`, `environment`,
  `sha`, `confirm`;
- `inputs.envs || vars.ENVS || 'dev,staging,prod'` as the only place the
  list of enabled environments appears (the D15 roles dev, staging and prod are
  fixed by the contract; ENVS says which ones a project has);
- the v10 prod path above (event map, guard, `environment: prod` jobs);
- every logic file is a real reusable workflow (`workflow_call`, its own
  `runs-on`, no `uses:` into this repository, no run-time dependency on it),
  and every stub calls the logic at the version its marker states.

## Checks

`lint.yml` runs on every push and pull request of this repository:
[actionlint](https://github.com/rhysd/actionlint) on `.github/workflows` and
`stubs/`, shellcheck on `scripts/` and `tests/`, `scripts/contract-check.sh`,
`tests/contract-check.test.sh` (broken copies of the tree, including the
d372cff self-calling `build.yml` in `tests/fixtures/`, must fail) and
`tests/install.test.sh` (both modes, actionlinted). Locally:

```sh
actionlint -shellcheck= && actionlint -shellcheck= stubs/*/*.yml
shellcheck scripts/*.sh tests/*.sh
bash scripts/contract-check.sh && bash tests/contract-check.test.sh && bash tests/install.test.sh
```

## Where this repository lives

Canonical: `git.emergy.cloud/emergy-cloud/workflows` (Forgejo), push-mirrored
to `github.com/emergy-cloud/workflows`, the copy GitHub Actions resolves
`uses:` against. Edit on Forgejo; never push to the GitHub copy directly.
