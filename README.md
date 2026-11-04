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
| `actions/select-images`  | picks which images from a JSON list to build       |


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

## Selective image builds

A repository that builds several images (for example `golden-images`) should not rebuild all of them when one changed. `actions/select-images` narrows the build matrix to the images that need a rebuild. `image-build.yml` still builds exactly one image: selection happens before the matrix, in the caller.

### Process

1. The repository keeps `images.json`, the single list of images: `[{"name", "context", "smoke"?, "variant"?}]`. `variant` is for several images built from one `context` with different Docker targets (`runtime`: `go`, `node`, `python`).
2. A job with a full checkout (`fetch-depth: 0`) runs the action. It outputs `matrix` (`{"include":[...]}`) and `empty` (`true` when nothing is selected).
3. The build job takes `matrix` through `fromJSON` and is skipped when `empty` is `true`.
4. Every matrix entry calls `image-build.yml` and builds one image.

### What gets selected

| Event                                  | Selected images                                                       |
| -------------------------------------- | --------------------------------------------------------------------- |
| `workflow_dispatch` with a list        | the listed ones: `name` (all variants), `name:variant` (one), comma-separated; an unknown name fails the step and prints the valid names |
| `workflow_dispatch` with `all` or empty | all                                                                   |
| `schedule`                             | all (the weekly run picks up base image patches)                      |
| `pull_request`                         | diff from the merge-base with the target branch to the PR head        |
| `push` to `main`                       | diff from the head of the last successful `build.yml` run on `main`   |
| anything else, or no usable base       | all                                                                   |

Diff rules:

- `*.md` files are ignored first.
- A changed file outside every `context` (the workflow, `images.json`, linter configs) selects all images.
- Otherwise an image is selected when a changed file is under its `context/`. All `variant`s of one `context` are selected together.
- Nothing left after filtering: the matrix is empty and the build job is skipped.

The push base is the last successful run, not `github.event.before`. With `cancel-in-progress`, a quick second push cancels the first run, and a base taken from `before` would lose the first push's changes. A failed image keeps the base behind, so the next run rebuilds more, never less. The first run on `main` has no successful run and builds everything. If the API call fails, the base is empty and everything is built.

### Caller

```yaml
permissions:
  contents: read
  actions: read

jobs:
  select:
    runs-on: ["self-hosted", "homelab"]
    outputs:
      matrix: ${{ steps.select.outputs.matrix }}
      empty: ${{ steps.select.outputs.empty }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: select
        uses: as-platform/ci-templates/actions/select-images@main
        with:
          images-file: images.json
          selection: ${{ inputs.images }}

  build:
    needs: select
    if: needs.select.outputs.empty != 'true'
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.select.outputs.matrix) }}
    uses: as-platform/ci-templates/.github/workflows/image-build.yml@main
    with:
      name: ${{ matrix.name }}
      context: ${{ matrix.context }}
      target: ${{ matrix.variant }}
      smoke: ${{ matrix.smoke }}
      registry: ${{ vars.ZOT_REGISTRY }}
      push: ${{ github.event_name != 'pull_request' }}
    secrets: inherit
```

Each job is a separate runner pod, so in a real repository put the `select` step into an existing job that already has the full checkout (as `golden-images` does with `lint`) instead of adding a job. Add a string input `images` (default `all`) to `workflow_dispatch`, and list `images.json` and the workflow itself in the `paths` of `push` and `pull_request`: otherwise a change to only those files does not start the workflow at all.

### Tags

Tags are not part of the action: the caller passes them to `image-build.yml`. Only built images get new tags. Images that were not selected keep the tags from their last build, and no tag with the current commit exists for them.

In `golden-images` the scheme is:

| Image                                                  | Tags                                         |
| ------------------------------------------------------ | -------------------------------------------- |
| `go-builder`, `node-builder`, `python-base`, `github-runner` | `YYYYMMDD-<sha7>` (primary), `stable`        |
| `runtime`                                              | `<variant>-YYYYMMDD-<sha7>` (primary), `<variant>` |

Example: a push that changes only `images/go-builder/` rebuilds `go-builder` and gives it `20261105-abc1234` and `stable`. `node-builder` keeps its previous `stable`, and the tag `20261105-abc1234` does not exist for it. Pull requests run with `push: false`: images are built, scanned and smoke-tested, but no tags are written.

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
