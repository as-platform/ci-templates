# ci-templates

Reusable workflows и composite actions для CI/CD сервисов. Сервис из шаблона Backstage подключает их тонкими вызывающими workflow.

Все workflow выполняются на эфемерном раннере `["self-hosted","homelab"]` (параметр `runner`). Каждый job поднимает отдельный под через KEDA, поэтому внутри workflow один job с последовательными шагами, без параллельных jobs.

## Workflow


| Файл              | Что делает                                                              |
| ----------------- | ----------------------------------------------------------------------- |
| `go-ci.yml`       | golangci-lint, `go test` с покрытием, `go build`                        |
| `python-ci.yml`   | uv sync, ruff, (mypy), pytest                                           |
| `node-ci.yml`     | pnpm/yarn/npm, скрипты `lint`, `typecheck`, `test`, `build` (если есть) |
| `monorepo-ci.yml` | выбирает изменённые сервисы по пути и вызывает CI нужного языка         |
| `security.yml`    | gitleaks, trivy fs (vuln, secret, misconfig), hadolint, semgrep         |
| `image-build.yml` | buildah build, Trivy, SBOM, push в Zot, cosign sign и attest            |
| `deploy-bump.yml` | меняет `image.tag` в `apps/<app>/values.yaml` репозитория platform      |


## Actions


| Каталог                  | Назначение                                     |
| ------------------------ | ---------------------------------------------- |
| `actions/zot-login`      | `buildah login` в Zot                          |
| `actions/cosign-sign`    | подпись образа по дайджесту и attestation SBOM |
| `actions/bump-image-tag` | правка тега в platform: прямой коммит или PR   |


## Пример: сервис на Go

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

## Пример: монорепозиторий

```yaml
jobs:
  ci:
    uses: as-platform/ci-templates/.github/workflows/monorepo-ci.yml@main
    with:
      services: >-
        [{"name":"api","path":"services/api","language":"go"},
         {"name":"web","path":"services/web","language":"node"}]
```

Если изменился файл вне путей сервисов (общий конфиг), запускаются все сервисы. Изменения только в `*.md` игнорируются. Образы монорепо собираются вызовами `image-build.yml` с `context` и `name` каждого сервиса.

## Что нужно настроить


| Тип        | Имя                                     | Где используется                                       |
| ---------- | --------------------------------------- | ------------------------------------------------------ |
| переменная | `ZOT_REGISTRY`                          | `image-build`                                          |
| секрет     | `ZOT_USER`, `ZOT_PASSWORD`              | `image-build`                                          |
| секрет     | `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD` | `image-build`                                          |
| секрет     | `PLATFORM_TOKEN`                        | `deploy-bump`: доступ на запись в репозиторий platform |


Эти значения удобнее задать один раз на уровне организации.

## Контракт с остальными репозиториями

- Репозиторий должен быть публичным, либо в его настройках Actions нужно разрешить доступ из организации. Иначе сервисы не смогут вызывать workflow.

- `values.yaml` в `platform/apps/<app>/` должен содержать блок `image:` со строкой `tag:`. Другие `tag:` вне этого блока не затрагиваются.
- Для Python версия по умолчанию 3.11 совпадает с `golden/runtime:python`.
- Образы для `Dockerfile` сервисов берутся из `golden-images` (`golden/go-builder`, `golden/runtime:go` и т.д.).

## Ограничения

- На раннере нет gcc, поэтому `go test -race` выключен по умолчанию (параметр `race`).
- `golangci-lint` по умолчанию `latest`; для воспроизводимости зафиксируй `golangci-lint-version`.
- Версии actions заданы тегами; Renovate закрепит их по дайджестам.

