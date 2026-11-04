# ci-templates

🇬🇧 [English version](README.md)

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
| `actions/select-images`  | выбор образов из JSON-списка для сборки        |


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

## Выборочная сборка образов

Репозиторий, который собирает несколько образов (например `golden-images`), не должен пересобирать все, когда изменился один. `actions/select-images` сужает матрицу сборки до образов, которым нужна пересборка. `image-build.yml` по-прежнему собирает ровно один образ: выбор происходит до матрицы, в вызывающем workflow.

### Процесс

1. В репозитории лежит `images.json` — единый список образов: `[{"name", "context", "smoke"?, "variant"?}]`. `variant` нужен, когда из одного `context` собираются несколько образов с разными Docker target (`runtime`: `go`, `node`, `python`).
2. Job с полным checkout (`fetch-depth: 0`) запускает action. Он отдаёт `matrix` (`{"include":[...]}`) и `empty` (`true`, если ничего не выбрано).
3. Job сборки берёт `matrix` через `fromJSON` и пропускается, когда `empty` равен `true`.
4. Каждый элемент матрицы вызывает `image-build.yml` и собирает один образ.

### Что выбирается

| Событие                                | Выбранные образы                                                      |
| -------------------------------------- | --------------------------------------------------------------------- |
| `workflow_dispatch` со списком         | перечисленные: `name` (все варианты), `name:variant` (один), через запятую; неизвестное имя валит шаг и печатает допустимые имена |
| `workflow_dispatch` с `all` или пустой | все                                                                   |
| `schedule`                             | все (недельный запуск подтягивает патчи базовых образов)              |
| `pull_request`                         | diff от merge-base с целевой веткой до head PR                        |
| `push` в `main`                        | diff от head последнего успешного рана `build.yml` на `main`          |
| остальное или нет пригодной базы       | все                                                                   |

Правила diff:

- Сначала отбрасываются файлы `*.md`.
- Изменённый файл вне всех `context` (workflow, `images.json`, конфиги линтеров) выбирает все образы.
- Иначе образ выбран, если изменённый файл лежит под его `context/`. Все `variant` одного `context` выбираются вместе.
- Если после фильтрации ничего не осталось, матрица пуста и job сборки пропускается.

База для push — последний успешный ран, а не `github.event.before`. При `cancel-in-progress` быстрый второй push отменяет первый ран, и база из `before` потеряла бы изменения первого push. Упавший образ оставляет базу позади, поэтому следующий ран пересоберёт больше, но не меньше. У первого рана на `main` успешных ранов нет, он собирает всё. Если запрос к API упал, база пуста и собирается всё.

### Вызывающий workflow

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

Каждый job — отдельный pod раннера, поэтому в реальном репозитории шаг `select` лучше добавить в уже существующий job с полным checkout (как `golden-images` делает в `lint`), а не заводить новый job. В `workflow_dispatch` нужен строковый input `images` (по умолчанию `all`), а `images.json` и сам workflow надо перечислить в `paths` для `push` и `pull_request`: иначе правка только этих файлов вообще не запустит workflow.

### Теги

Теги не относятся к action: их передаёт в `image-build.yml` вызывающий workflow. Новые теги получают только собранные образы. Невыбранные образы сохраняют теги прошлой сборки, и тега с текущим коммитом у них нет.

В `golden-images` схема такая:

| Образ                                                        | Теги                                         |
| ------------------------------------------------------------ | -------------------------------------------- |
| `go-builder`, `node-builder`, `python-base`, `github-runner` | `YYYYMMDD-<sha7>` (основной), `stable`       |
| `runtime`                                                    | `<variant>-YYYYMMDD-<sha7>` (основной), `<variant>` |

Пример: push, меняющий только `images/go-builder/`, пересобирает `go-builder` и даёт ему `20261105-abc1234` и `stable`. У `node-builder` остаётся прежний `stable`, а тега `20261105-abc1234` для него не существует. Pull request идёт с `push: false`: образы собираются, сканируются и проходят smoke, но теги не пишутся.

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

