# Design: GitHub Actions build/push for the `redis` image (GHCR)

## Goal

Replace the manual, AWS-ECR-based build/push flow for the `redis` image with a
GitHub Actions workflow that builds a multi-arch (amd64+arm64) image whenever
its source files change, and pushes it to GitHub Container Registry (GHCR)
instead of the private ECR. This is the first image migrated; `rabbitmq` and
`os-shell` will follow the same template in later work.

## Scope

- In scope: `images/redis/**` only.
- Out of scope: `rabbitmq`, `os-shell` (revisit after this template is
  validated), the missing `images/build-utils/` scripts (pre-existing known
  gap, unrelated to this change), and the S3 source-backup flow
  (`copy-image-sources-s3.sh`), which is unrelated to the registry target and
  is left as-is.

## Registry & naming

- Registry: GHCR (`ghcr.io`), replacing the private ECR
  (`569129334545.dkr.ecr.us-east-1.amazonaws.com`).
- Image path: `ghcr.io/<owner>/<repo>/redis`, derived from the `github.repository`
  context (`mindw/odd_images`) rather than hardcoded, so it resolves to
  `ghcr.io/mindw/odd_images/redis`. No `bitnami/` prefix.
- Package visibility: GHCR packages default to private even in a public repo.
  Making the `redis` package public after the first push is a **manual,
  one-time step** in GitHub package settings — not automated by this workflow
  (the default `GITHUB_TOKEN` can't change package visibility).

## Workflow file

New file: `.github/workflows/redis.yml`.

Triggers:

```yaml
on:
  push:
    branches: [main]
    paths: ["images/redis/**", ".github/workflows/redis.yml"]
  pull_request:
    paths: ["images/redis/**", ".github/workflows/redis.yml"]
```

Single job (`build`), no matrix (Approach A: one buildx job using QEMU
emulation for arm64, chosen over a native per-arch matrix + manifest-merge
job for simplicity as a first template — this repo's Dockerfile only
downloads prebuilt Bitnami binaries and installs apt packages, so emulation
overhead should be minor; revisit with the native-runner approach later if
build times become a real problem).

- `pull_request`: builds both platforms, does **not** push. Pure validation
  that the Dockerfile still builds. No GHCR login performed.
- `push` to `main`: builds both platforms, logs into GHCR, pushes all
  derived tags.

## Version & tag derivation

`images/redis/current/debian-12/version.sh` must be **sourced**, not
executed, because it `export`s variables (`REDIS_APP_VERSION`,
`REDIS_IMAGE_REVISION`, `REDIS_OS_FLAVOUR`, `REDIS_VERSION`) that only
survive in the calling shell if sourced.

A step resolves the image tags and writes them to `$GITHUB_OUTPUT`:

```yaml
- name: Resolve version and tags
  id: version
  run: |
    source images/redis/current/debian-12/version.sh
    IMAGE="ghcr.io/${{ github.repository }}/redis"
    MAJOR_MINOR="${REDIS_APP_VERSION%.*}"
    {
      echo "tags<<EOF"
      echo "${IMAGE}:${REDIS_VERSION}"
      echo "${IMAGE}:v${REDIS_APP_VERSION}"
      echo "${IMAGE}:v${MAJOR_MINOR}"
      echo "${IMAGE}:latest"
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
```

All four tags (`VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, `latest`) are
pushed together in one shot on every successful `main` build — no separate
manual "promote to latest" step, unlike the old ECR flow.

This step runs on every trigger (PR and push) so the build step always knows
the intended tags; only the `push` event actually pushes them.

## Build & push steps

```yaml
permissions:
  contents: read
  packages: write

steps:
  - uses: actions/checkout@v4
  - uses: docker/setup-qemu-action@v3
  - uses: docker/setup-buildx-action@v3
  - name: Resolve version and tags
    id: version
    run: |
      # (see above)
  - name: Log in to GHCR
    if: github.event_name == 'push'
    uses: docker/login-action@v3
    with:
      registry: ghcr.io
      username: ${{ github.actor }}
      password: ${{ secrets.GITHUB_TOKEN }}
  - name: Build and push
    uses: docker/build-push-action@v6
    with:
      context: images/redis/current/debian-12
      platforms: linux/amd64,linux/arm64
      push: ${{ github.event_name == 'push' }}
      tags: ${{ steps.version.outputs.tags }}
      cache-from: type=gha
      cache-to: type=gha,mode=max
```

No secret is needed for the Bitnami download URL — the Dockerfile's
`DOWNLOADS_URL` ARG already has a public default, and the optional
`--mount=type=secret` override is not required for this build.

## README & reference rewrite

`images/redis/README.md` currently has 40 occurrences of the ECR host /
`bitnami/redis` / `skopeo` across its sections. Rewrite:

- Replace every `569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/redis`
  with `ghcr.io/mindw/odd_images/redis` throughout (TL;DR, "Get this image",
  cluster examples, upgrade steps).
- Replace the `skopeo list-tags ...` snippet with a pointer to the GHCR
  package page instead.
- Rewrite "Engageli notes → Updating to a new version" to describe the new
  flow: bump `Dockerfile`/`version.sh` → open a PR (CI validates the
  multi-arch build) → merge to `main` (CI builds and pushes all tags
  automatically). Drop the old manual "promote latest" and "propagate to
  dev/prod via `aws/misc/ecr.py`" steps — CI now does this in one push.
- Update the image reference in all 3 docker-compose files:
  `images/redis/docker-compose.yml`, `images/redis/docker-compose-replicaset.yml`,
  `images/redis/current/debian-12/docker-compose.yml`.
- Delete `images/redis/redis-build-and-push.sh` — its only job (build+push to
  ECR) is fully replaced by the workflow. `copy-image-sources-s3.sh` is kept
  as-is (unrelated to the registry target).

## Testing / verification

No automated test suite exists for this repo (Bash/Docker infra, not app
code). Verification for this change means:

- The workflow YAML is valid (`actionlint` or GitHub's own validation on
  push/PR).
- A real PR touching `images/redis/**` triggers the workflow and the
  build-only job succeeds for both platforms.
- After merging to `main`, the push job succeeds and all four tags are
  visible on the GHCR package page, and `docker pull
  ghcr.io/mindw/odd_images/redis:latest` (once the package is made public)
  actually runs.

## Follow-ups (explicitly out of scope for this change)

- Making the GHCR `redis` package public (manual, one-time).
- Replicating this workflow to `rabbitmq` and `os-shell`.
- Revisiting Approach B (native arm64 runner + manifest merge) if QEMU build
  times become a problem.
- The missing `images/build-utils/` scripts remain a known, pre-existing gap
  — unrelated to this change since the new workflow doesn't depend on them.
