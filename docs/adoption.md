# Adopting contract v10 in a repository

For HQ roadmap items 9 (templates) and 10 (products). One repository per commit; the owner pushes. Read the
[README](../README.md) for the prod path and the install command; the design is in
[the spec](specs/shared-ci-v10.md) and [ADR 0001](adr/0001-d15-prod-path-and-vendoring.md).

## Before you start

- Tags: `git -C /repos/workflows tag -l 'v9*' 'v10*'`. Until the owner has created and fetched `v10.0.0` and
  `v10`, ref mode still works (the stub templates come from `HEAD`, said in the output) and vendor mode needs a
  revision that exists here (`--ref origin/main` or a sha; the header stamps the resolved sha). Re-run with
  `--ref v10.0.0` once the tag exists so the stamp names the release.
- Never run the installer with `--target /repos/workflows` (it refuses).

## Per repository

| Repository | Org (D4) | Mode | Command (from `/repos/workflows`) | Today |
|---|---|---|---|---|
| ssr-website-auth-astro-template | emergy-cloud-templates | ref, auto | `scripts/install.sh --mode ref --ref v10 --target /repos/ssr-website-auth-astro-template` | inline v7, fallback `dev,prod` |
| ssr-website-astro-template | emergy-cloud-templates | ref, auto | `scripts/install.sh --mode ref --ref v10 --target /repos/ssr-website-astro-template` | inline v7, fallback `dev,prod` |
| static-website-astro-template | emergy-cloud-templates | ref, auto | `scripts/install.sh --mode ref --ref v10 --target /repos/static-website-astro-template` | inline v6, fallback `dev,prod` |
| static-doc-starlight-template | emergy-cloud-templates | ref, auto | `scripts/install.sh --mode ref --ref v10 --envs dev,prod --target /repos/static-doc-starlight-template` | pre-contract, no fallback |
| www.boulot.ai | (Forgejo `6be709c0`) | ref, auto or pinned | `scripts/install.sh --mode ref --ref v10 --target /repos/www.boulot.ai` | inline v7, fallback `dev,prod` |
| recapify.app | emergy-cloud-projects | ref, auto or pinned | `scripts/install.sh --mode ref --ref v10 --target /repos/recapify.app` | inline v7 + `ci.yml`, `claude.yml` |
| www.emergy.cloud | emergy-cloud | ref, auto or pinned | `scripts/install.sh --mode ref --ref v10 --target /repos/www.emergy.cloud` | inline v7 + `ci.yml`, fallback `dev,staging,prod` |
| app.upmatch.io | upmatch-io | **vendor** | `scripts/install.sh --mode vendor --ref v10.0.0 --target /repos/app.upmatch.io` | pre-contract |
| app.storeai.dev | Store-AI-Group-Inc | **vendor** | `scripts/install.sh --mode vendor --ref v10.0.0 --envs <its envs> --target /repos/app.storeai.dev` | CI disabled (`.disabled-github/`) |
| delinecor.com | delinecor | **vendor** | `scripts/install.sh --mode vendor --ref v10.0.0 --target /repos/delinecor.com` | inline v6, fallback `dev,prod` |

Pinned instead of auto: `--ref v10.0.0` in ref mode (the owner decides per product; the default is auto).
A repository later created from a template inside an excluded org must be re-run in vendor mode, because the
template's stubs name `emergy-cloud/workflows`.

## Steps for one repository

1. **Read what you replace.** Diff the repository's current `build.yml`, `deploy.yml`,
   `update-infrastructure.yml`, `delete-infrastructure.yml` against the v10 logic
   (`/repos/workflows/.github/workflows/`). Anything repository-specific (an extra step, other bucket or Lambda
   names, other variables) must be handled before the switch or the switch waits. The shared logic expects:
   website buckets `<PROJECT_ID>-<env>-website`, artifact bucket `<PROJECT_ID>-artifacts` (or `ARTIFACT_BUCKET`),
   SSR Lambda `<PROJECT_ID>_<env>_website_ssr`, worker `<PROJECT_ID>-worker`, CloudFront distributions tagged
   `env` and `projectId`, terraform in `infrastructure/` with the S3 backend (`TF_BACKEND_BUCKET`,
   `TF_STATE_KEY_PREFIX`), the site in `website/`. Pre-contract repositories (upmatch, starlight) differ most.
2. **Run the command** from the table. It prints every file it writes: 4 in ref mode, 8 in vendor mode.
   `ci.yml`, `claude.yml` and every other file stay untouched.
3. **Verify** in the repository:
   - `git status --short` lists only those files;
   - `actionlint -shellcheck= .github/workflows/{build,deploy,update-infrastructure,delete-infrastructure}.yml`
     (plus `.github/workflows/vendored-*.yml` in vendor mode) passes; run it inside the repository so the local
     `vendored-*` calls are resolved;
   - vendor mode (D4): `grep -nE '^[^#]*emergy-cloud/workflows' .github/workflows/*.yml` prints nothing, for
     every workflow file of the repository, not only the eight;
   - the ENVS fallback printed by the installer is the repository's real environment list;
   - storeai only: decide in the same commit what happens to `.disabled-github/` (the installer does not touch it).
4. **Commit** in the repository (plain message naming the contract and ref, for example
   `CI: adopt emergy.cloud workflow contract v10 (ref v10)`), then ask the owner to push.

## Owner settings per repository (GitHub, once)

- **`prod` environment with required reviewers** and deployment branch `main` (README, "Approval setup"). Without
  it, merges stop at staging and prod is deployed by hand. Check the plan: GitHub documents required reviewers on
  private repositories only for GitHub Enterprise.
- **Repository variables**: already set by the emergy platform for platform projects (`PROJECT_ID`, `AWS_REGION`,
  `AWS_ACCOUNT_ID`, `AWS_INFRA_ROLE_TO_ASSUME`, `ENVS`, `TF_BACKEND_BUCKET`, `TF_STATE_KEY_PREFIX`,
  `HOSTNAME_<ENV>`, `AWS_WEBSITE_ACM_ARN_<ENV>`, `AWS_WEBSITE_ACM_NAME_<ENV>`); optional `FORGEJO_REPO` with the
  secret `FORGEJO_STATUS_TOKEN` for the Forgejo commit status. Repositories outside the platform (upmatch,
  storeai) need the same names set by hand: names only here, values come from their owners.
- **Actions policy** (ref mode): Settings > Actions > General must allow the reusable workflows of
  `emergy-cloud/workflows` (an org that allows only local actions blocks them).
- Keep CI variables at repository level: variables on the `prod` environment override them inside prod jobs.

## After the push (watch one full cycle on GitHub Actions)

1. Push a branch touching `website/`: Build, then `Deploy dev @ <sha>`.
2. Open a pull request to `main` on GitHub: its run builds and deploys nothing. (Forgejo pull requests never
   reach GitHub; only their branch pushes do, which deploy dev.)
3. Merge to `main`: Build, then `Deploy staging @ <sha>`; its last step "Request prod promotion (needs approval)"
   either dispatches `Deploy prod @ <same sha>` (now waiting for review) or explains why it did not.
4. Approve the prod run: it deploys the same artifact.
5. For a repository without staging, step 3 is replaced by Build requesting `Deploy prod @ <sha>` directly.

## Bumping later

Run the same command with the new ref (`--ref v10.1.0`, `--ref v11`), review `git diff`, commit. A new major also
brings new stubs (re-read the README for what changed). www.emergy.cloud additionally re-syncs its served stubs:
`WORKFLOWS_DIR=/repos/workflows WORKFLOWS_REF=v10.0.0 pnpm --dir website workflows:sync`.
