# Spec: shared CI contract v10 (D15 prod path, versioning, lint guard, stubs, install command)

**Status:** draft, built overnight, pending owner approval
**Owner:** Math (owner), drafted by the overnight agent
**Date:** 2026-10-28
**Roadmap:** HQ Phase 1c step 1 (item 8). Workstream: HQ `docs/workstreams/5-shared-ci.md`. Decisions: D4, D5,
D9, D14, D15. Owner answers for this item: prod approval is a GitHub environment protection rule (required
reviewers) on `prod`; the stub generator moves to this repository and emergy.cloud fetches the stubs from here.

## Intent (one sentence)

> CI drifts per repository, fixes do not propagate, the shared workflows have no adopter, and no repository has an
> audited path to prod (a merge either deploys prod with no review or deploys nothing).

## Outcome / success criteria

- [ ] Contract **v10** implements D15: a branch push deploys dev, a push to `main` deploys staging, a pull request
      only builds, and prod receives the **same artifact** (same sha, no rebuild) only after a required reviewer
      approves the `prod` environment.
- [ ] Prod can never be deployed by a push without an approval: the promotion is requested only when `prod` is
      enabled and the repository's `prod` environment has a `required_reviewers` rule; otherwise the run says why
      and skips.
- [ ] Immutable semver tags `vX.Y.Z` next to the moving major `vX` are documented with exact commands; `v9` stays
      frozen (`v9.0.0` = today's `v9` commit).
- [ ] `lint.yml` fails when a logic file is self-calling (calls a workflow, lacks `workflow_call`, lacks
      `runs-on`) and when a stub does not call the version its marker states; a fixture test proves it.
- [ ] The canonical stubs live here (`stubs/astro/`); www.emergy.cloud syncs them from here and serves v10.
- [ ] One command (`scripts/install.sh`) writes CI into a repository in reference mode (`@v10` or a pinned
      `@v10.0.0`) or vendored mode (D4/D9 orgs), touches only its own files, and is the same command that bumps.
- [ ] Items 9 and 10 can follow `docs/adoption.md` without reading this spec.

## In scope

- v10 shared logic (`.github/workflows/build.yml`, `deploy.yml`, `update-infrastructure.yml`,
  `delete-infrastructure.yml`): event map, approval-gated promotion, prod-targeting jobs under `environment: prod`.
- v10 stubs in `stubs/astro/` (marker `# emergy.cloud workflow contract: astro v10`).
- Version scheme and tag commands (documented, not executed).
- `scripts/contract-check.sh` lint guard, `tests/` scripts and fixtures, `lint.yml` wiring.
- `scripts/install.sh` (modes `ref` and `vendor`), offline, bash.
- README, `docs/adoption.md`, this spec and ADR 0001.
- www.emergy.cloud: a stub sync script, the synced v10 stubs with a recorded source, `WORKFLOW_CONTRACT_VERSION = 10`,
  its tests, and the user-facing copy that says a merge deploys prod.

## Out of scope (read this twice)

- Adopting v10 in any repository (items 9 and 10), including www.emergy.cloud's own `.github/workflows`.
- Creating, moving or pushing any tag; any push; any GitHub, Forgejo or AWS setting (the owner does those).
- Changing what v9 means (v9 stays as tagged).
- Rewriting build or deploy logic beyond the prod path (no new caching, no new stacks, no Forgejo Actions).
- The emergy.cloud platform creating protected `prod` environments for its users, `dvk ship`, retiring the
  per-repository release CLIs, secrets.
- Template lego manifests (WS3).

## User stories

- As the owner, I merge to `main` and staging deploys by itself; I get one approval request for prod with the same
  artifact, and nothing reaches prod until I approve.
- As the owner, I choose per repository whether it follows `v10` or stays pinned to `v10.0.0`.
- As an agent running items 9 and 10, I install or bump CI in a repository with one command, in reference or
  vendored mode.
- As a maintainer of this repository, lint stops me before a logic file turns into a stub calling itself.
- As an emergy.cloud user, the CI/CD reference shows the v10 files and the guide explains the new path.

## Acceptance criteria

- [ ] Given a v10 repository, when a branch other than `main` is pushed, then Build builds, uploads and dispatches
      Deploy for `dev` only (skipped with a log line when `dev` is not in ENVS).
- [ ] Given a v10 repository, when a pull request to `main` is opened or updated, then Build builds without AWS
      credentials, uploads nothing and dispatches nothing.
- [ ] Given ENVS contains `staging`, when `main` receives a push, then Build dispatches Deploy `staging` for that
      sha; when that deploy succeeds, the sha is on `main`, `prod` is in ENVS and the `prod` environment has a
      `required_reviewers` rule, then Deploy `prod` is dispatched with the same sha and its job waits for approval.
- [ ] Given the guard is not met (prod not enabled, no `prod` environment, no required reviewers, the deploy did
      not run from `main`, or the sha is not on `main`), then no prod run is created and the run shows a notice or
      warning that says which condition failed.
- [ ] Given a Deploy `prod` run for the same sha is already queued, waiting, running or succeeded, then no second
      promotion is requested.
- [ ] Given ENVS has no `staging` (for example `dev,prod`), when `main` receives a push, then Build applies the same
      guard and requests Deploy `prod` directly (ASSUMED, see open questions).
- [ ] Given `prod` is enabled, then the infrastructure apply and destroy jobs run under `environment: prod`.
- [ ] Given a logic file that calls `emergy-cloud/workflows/...` or `./.github/workflows/...`, lacks a
      `workflow_call` trigger or lacks `runs-on`, when `lint.yml` runs, then `scripts/contract-check.sh` fails
      (`tests/contract-check.test.sh` proves each case).
- [ ] Given `scripts/install.sh --mode ref --ref v10.0.0 --envs dev,prod --target <repo>`, then exactly the four
      stubs are written, calling `@v10.0.0` with the `'dev,prod'` fallback, and nothing else changes.
- [ ] Given `scripts/install.sh --mode vendor --ref <tag|branch|sha> --target <repo>`, then the four stubs call
      `./.github/workflows/vendored-<name>.yml`, the four vendored files carry
      `# vendored from emergy-cloud/workflows@<ref> (<sha>): do not edit, refresh with scripts/install.sh`, and no
      file has a non-comment line naming `emergy-cloud/workflows`.
- [ ] Given www.emergy.cloud after the sync, then its four stubs equal `stubs/astro/` at the recorded sha,
      `WORKFLOW_CONTRACT_VERSION` is 10 and its workflow tests pass.
- [ ] actionlint passes on this repository, on the stubs and on install output in both modes; shellcheck passes on
      every script touched.

## Open questions

- **GitHub plan.** Required reviewers on an environment are offered for public repositories on every plan, but
  for private repositories only on higher plans (GitHub documents GitHub Enterprise for "other protection rules"
  in private repositories; to verify for each org). Where the rule cannot be set, the guard skips and prod stays
  a manual deploy (platform button, `dvk ship`, or a Deploy run). Decide per org: plan, public repo, or manual prod.
- **Repositories without staging** (`dev,prod`: the templates, boulot, recapify, delinecor, most platform
  projects). Assumed: a push to `main` requests the approval-gated prod promotion directly. Alternative: such a
  push deploys nothing. Confirm.
- **Destroy under `environment: prod`.** Assumed yes (it destroys prod). When prod is protected, a project deletion
  from the platform waits for that approval. Confirm.
- Should emergy.cloud create the protected `prod` environment for its users (its GitHub App already writes
  environments)? Later item.
- What happens to the per-repository release CLIs once v10 lands (existing HQ open question).

---
*GATE 1: the owner approves this spec before moving to DESIGN (`docs/adr/0001-d15-prod-path-and-vendoring.md`).*
