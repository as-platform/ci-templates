# ci-templates

🇷🇺 [Русская версия](README_RUS.md)

Reusable workflows and composite actions for service CI/CD. A service created from a Backstage template connects to them through thin caller workflows.

All workflows run on an ephemeral runner `["self-hosted","homelab"]` (the `runner` parameter). Each job spins up a separate pod through KEDA, so every workflow has a single job with sequential steps and no parallel jobs.

## Workflows


| File              | What it does                                                            |
| ----------------- | ----------------------------------------------------------------------- |
| `go-ci.yml`       | golangci-lint, `go test` with coverage, `go build`                      |
| `python-ci.yml`   | uv sync, ruff, (mypy), pytest                                           |
| `node-ci.yml`     | pnpm/yarn/npm, `lint`, `typecheck`, `test`, `build` scripts (if present) |
| `monorepo-ci.yml` | picks changed services by path and calls the CI for the right language  |
| `security.yml`    | gitleaks, trivy fs (vuln, secret, misconfig), hadolint, semgrep         |
| `image-build.yml` | buildah build, Trivy, SBOM, push to Zot, cosign sign and attest         |
| `deploy-bump.yml` | changes `image.tag` in `apps/<app>/values.yaml` of the platform repository |


## Actions


| Directory                | Purpose                                            |
| ------------------------ | -------------------------------------------------- |
| `actions/zot-login`      | `buildah login` to Zot                             |
| `actions/cosign-sign`    | signs the image by digest and attests the SBOM     |
| `actions/bump-image-tag` | edits the tag in platform: direct commit or PR     |


## Example: a Go service

```yaml
name: ci
on:
  push: { branches: [main], tags: ["v*"] }
  pull_request:

jobs:
  ci:
    uses: as-platform/ci-templates/.github/workflows/go-ci.yml@main

  security:
    uses: as-platform/ci-templates/.github/workflows/security.yml@main

  image:
    needs: [ci, security]
    uses: as-platform/ci-templates/.github/workflows/image-build.yml@main
    with:
      name: my-service
      registry: ${{ vars.ZOT_REGISTRY }}
      push: ${{ github.event_name != 'pull_request' }}
    secrets: inherit

  deploy:
    if: github.event_name != 'pull_request'
    needs: image
    uses: as-platform/ci-templates/.github/workflows/deploy-bump.yml@main
    with:
      app: my-service
      tag: ${{ needs.image.outputs.tag }}
    secrets: inherit
```

## Example: a monorepo

```yaml
jobs:
  ci:
    uses: as-platform/ci-templates/.github/workflows/monorepo-ci.yml@main
    with:
      services: >-
        [{"name":"api","path":"services/api","language":"go"},
         {"name":"web","path":"services/web","language":"node"}]
```

If a file outside the service paths changes (a shared config), all services run. Changes to `*.md` files only are ignored. Monorepo images are built by calling `image-build.yml` with each service's `context` and `name`.

## What to configure


| Type     | Name                                    | Where it is used                                          |
| -------- | --------------------------------------- | --------------------------------------------------------- |
| variable | `ZOT_REGISTRY`                          | `image-build`                                             |
| secret   | `ZOT_USER`, `ZOT_PASSWORD`              | `image-build`                                             |
| secret   | `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD` | `image-build`                                             |
| secret   | `PLATFORM_TOKEN`                        | `deploy-bump`: write access to the platform repository    |


It is more convenient to set these values once at the organization level.

## Contract with the other repositories

- The repository must be public, or Actions access from the organization must be allowed in its settings. Otherwise services cannot call the workflows.

- `values.yaml` in `platform/apps/<app>/` must contain an `image:` block with a `tag:` line. Other `tag:` entries outside this block are left untouched.
- For Python the default version 3.11 matches `golden/runtime:python`.
- Images for service `Dockerfile`s come from `golden-images` (`golden/go-builder`, `golden/runtime:go`, etc.).

## Limitations

- The runner has no gcc, so `go test -race` is off by default (the `race` parameter).
- `golangci-lint` defaults to `latest`; pin `golangci-lint-version` for reproducibility.
- Action versions are set by tags; Renovate will pin them by digest.
