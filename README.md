# emergy.cloud workflows

The CI/CD pipeline of every emergy.cloud project, as **reusable GitHub Actions
workflows** (`on: workflow_call`). This repository is public so a project in
any GitHub organization can call it; it holds no secrets and no project data.

| Shared workflow | Called by the stub | Does |
|---|---|---|
| `.github/workflows/build.yml` | `build.yml` | build the commit, upload `builds/<sha>/` to the artifact bucket, dispatch Deploy for the environment the event targets |
| `.github/workflows/deploy.yml` | `deploy.yml` | promote one built artifact to one environment (static assets, SSR Lambda, worker, CloudFront invalidation) |
| `.github/workflows/update-infrastructure.yml` | `update-infrastructure.yml` | `terraform apply` + GitHub Deployments per enabled environment |
| `.github/workflows/delete-infrastructure.yml` | `delete-infrastructure.yml` | `terraform destroy`, gated on the typed `confirm` input |

## How a project uses it

Each project repository keeps a **thin stub** per workflow under
`.github/workflows/` — the same four file names — holding only what must live
in the repository: the triggers, `permissions`, `concurrency`, the
`workflow_dispatch` inputs and the `ENVS` fallback. The stub calls the shared
logic:

```yaml
jobs:
  build:
    uses: emergy-cloud/workflows/.github/workflows/build.yml@v9
    with:
      envs: ${{ vars.ENVS || 'dev,staging,prod' }}
      deploy_all: ${{ inputs.deploy_all == true }}
      deploy_environments: ${{ inputs.deploy_environments || '' }}
    secrets: inherit
```

The stubs are served by emergy.cloud, rendered for the project's environments
(the `envs` input carries that fallback):

```sh
# from the repository root — writes/replaces the four files under .github/workflows
curl -fsSL 'https://emergy.cloud/api/workflows.sh?envs=dev,prod' | sh
```

`vars.*` (`PROJECT_ID`, `ENVS`, the AWS role ARNs…) and `secrets.*` resolve in
the **calling** repository, and the OIDC token carries the caller's identity,
so nothing changes on the AWS side when a project moves from a full copy of the
workflow to a stub.

## Versioning

- Tag **`v<N>`** = the line of emergy.cloud **workflow contract v<N>** (the
  marker on line 1 of every stub). A stub pinned to `@v9` follows that tag.
- A **logic fix** that keeps the inputs, job ids and names unchanged is
  released by moving the `v9` tag (`git tag -f v9 && git push -f origin v9`)
  — every repository picks it up on its next run, nothing to commit there.
- A **contract change** (a new input, trigger, file name or parsed name) is a
  new tag (`v10`) *and* a new stub served by emergy.cloud; its readiness
  checklist flags repositories whose stub marker is behind.

## Guarantees the platform relies on (kept by `scripts/contract-check.sh`)

- file names, job ids (`build`, `deploy`, `update`, `delete`) and the deploy
  job name `Deploy <env> from sha <sha>` (the webhook parses it);
- the dispatch inputs `deploy_all`, `deploy_environments`, `environment`,
  `sha`, `confirm`;
- `inputs.envs || vars.ENVS || 'dev,staging,prod'` as the only place the
  environment vocabulary appears.

`lint.yml` runs [actionlint](https://github.com/rhysd/actionlint) and that
check on every push and pull request of this repository.

## Where this repository lives

Canonical: `git.emergy.cloud/emergy-cloud/workflows` (Forgejo), push-mirrored
to `github.com/emergy-cloud/workflows` — the copy GitHub Actions resolves
`uses:` against. Edit on Forgejo; never push to the GitHub copy directly.
