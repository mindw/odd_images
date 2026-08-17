# Design: GitHub Actions build/push for the `os-shell` image (GHCR)

## Goal

Apply the same GHCR-based CI template used for `redis` and `redis-sentinel`
to `os-shell`, so it builds multi-arch (amd64+arm64) and publishes to GHCR
whenever its source files change, replacing the old manual AWS-ECR flow.

## Scope

- In scope: `images/os-shell/**` only.
- Out of scope: `rabbitmq` (still on the old ECR flow, to be migrated
  later).

## Current state (already cleaned up by the user, prior to this change)

Unlike `redis-sentinel` (first-time setup) and like `redis` (a real
migration), `os-shell` already has Engageli/ECR customization in its
README, but the user has already:

- Restructured it from `images/os-shell/12/debian-12/` to
  `images/os-shell/current/debian-12/`, matching `redis`/`redis-sentinel`'s
  layout.
- Added arm64 checksums for all 5 bundled components (`yq`,
  `wait-for-port`, `render-template`, `ini-file`, `scuttle`) — multi-arch
  is viable, confirmed via `ARG TARGETARCH` → `OS_ARCH` threading in the
  Dockerfile, same pattern as `redis`.
- Deleted the old `images/os-shell/os-shell-12-build-and-push.sh` and
  `images/os-shell/copy-image-sources-s3.sh` scripts, and the shared
  `images/add-tag-to-engageli-private-ecr-image.sh` script — so there is
  nothing left to delete as part of this change, only the README to
  rewrite.

No docker-compose files exist for `os-shell` (confirmed empty search) —
nothing to update there either.

## Registry & naming

- Image path: `ghcr.io/${{ github.repository }}/os-shell` →
  `ghcr.io/mindw/odd_images/os-shell`. The old README used two different
  ECR image names (`bitnami/os-shell-dev` for the dev-tagged pulls,
  `bitnami/os-shell` elsewhere) — both collapse into this single GHCR path
  since there's no dev/prod repo split with GHCR.
- Same 4-tag scheme: `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, `latest`,
  derived from `images/os-shell/current/debian-12/version.sh` (sources
  `extract-version-bitnami-images.sh ... OS_SHELL`, exporting
  `OS_SHELL_APP_VERSION`, `OS_SHELL_VERSION`, etc.).
- **Note:** `OS_SHELL_APP_VERSION` is `"12"` (a bare OS major version, not
  semver like `8.8.1`) — `${OS_SHELL_APP_VERSION%.*}` on a string with no
  `.` returns it unchanged, so `vMAJOR_MINOR` and `vAPP_VERSION` end up
  identical (`v12` both). Harmless: pushing the same tag value twice in one
  `docker/build-push-action` call is a no-op duplicate, not an error. Kept
  consistent with the established template rather than special-cased.

## Smoke test: architecturally different from redis/redis-sentinel

`os-shell` is not a long-running server — it's a one-shot utility image
(`docker run --rm os-shell ... <command>`). So unlike `redis`/`redis-sentinel`,
there's no daemon to start, poll, and tear down. The smoke test instead
directly invokes a real installed binary and checks it runs:

```yaml
- name: Smoke test
  run: |
    docker run --rm os-shell-smoke-test:local yq --version
```

`yq` is one of the 5 components fetched per-arch in the Dockerfile
(`PATH="/opt/bitnami/common/bin:$PATH"`), so this both confirms the image
runs at all and that the arch-specific binary fetch/install succeeded for
the platform being tested (amd64, same limitation as the other two
images' smoke tests — arm64 itself is never smoke-tested, only built).

## Workflow file

New file: `.github/workflows/os-shell.yml`, following the same shape as
the other two (concurrency guard, `provenance: false`, push-gated login):

```yaml
name: os-shell

on:
  push:
    branches: [main]
    paths:
      - "images/os-shell/**"
      - ".github/workflows/os-shell.yml"
  pull_request:
    paths:
      - "images/os-shell/**"
      - ".github/workflows/os-shell.yml"

concurrency:
  group: os-shell-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Resolve version and tags
        id: version
        run: |
          source images/os-shell/current/debian-12/version.sh
          IMAGE="ghcr.io/${{ github.repository }}/os-shell"
          MAJOR_MINOR="${OS_SHELL_APP_VERSION%.*}"
          {
            echo "tags<<EOF"
            echo "${IMAGE}:${OS_SHELL_VERSION}"
            echo "${IMAGE}:v${OS_SHELL_APP_VERSION}"
            echo "${IMAGE}:v${MAJOR_MINOR}"
            echo "${IMAGE}:latest"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Build amd64 image for smoke test
        uses: docker/build-push-action@v6
        with:
          context: images/os-shell/current/debian-12
          platforms: linux/amd64
          load: true
          tags: os-shell-smoke-test:local
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke test
        run: |
          docker run --rm os-shell-smoke-test:local yq --version

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
          context: images/os-shell/current/debian-12
          provenance: false
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: ${{ steps.version.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

## README rewrite

`images/os-shell/README.md` has:

- An "Engageli notes" section (lines 10-32) referencing the now-deleted
  `copy-image-sources-s3.sh`, `os-shell-12-build-and-push.sh`,
  `add-tag-to-engageli-private-ecr-image.sh`, and `aws/misc/ecr.py` —
  rewrite to describe the new CI flow (no backup-script step, since that
  script no longer exists for this image): bump `Dockerfile` → open a PR
  (CI validates + smoke-tests) → merge to `main` (CI builds, smoke-tests,
  pushes all 4 tags).
- 5 lines with the ECR host + `bitnami/os-shell`/`bitnami/os-shell-dev`
  registry references (TL;DR, "Get this image" pull + skopeo tag-list +
  versioned pull, "Running commands" example) — replace with
  `ghcr.io/mindw/odd_images/os-shell`, dropping the skopeo tag-listing
  snippet in favor of a GHCR package-page link, same as the other two
  images.
- Leave the generic "build the image yourself by cloning
  bitnami/containers" block untouched — it's about the upstream repo, not
  our registry.
- No GHCR-package-visibility caveat (same carried-over decision as the
  other two images).

## Testing / verification

Same as `redis`/`redis-sentinel`: `yq` YAML assertions, `grep` reference
checks, a real PR run (build-only + smoke test, both platforms), and a
real push-triggered run after merge.

## Follow-ups (out of scope)

- `rabbitmq` still needs the same migration — the last of the three
  original images.
