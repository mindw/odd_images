# Design: GitHub Actions build/push for the `redis-sentinel` image (GHCR)

## Goal

Apply the same GHCR-based CI template used for `redis` (see
`docs/superpowers/specs/2026-08-16-redis-ghcr-ci-design.md`) to the newly
added `redis-sentinel` image sources, so it builds multi-arch (amd64+arm64)
and publishes to GHCR whenever its source files change — matching the
now-established pattern instead of ever adopting the old AWS-ECR flow.

## Scope

- In scope: `images/redis-sentinel/**` only.
- Out of scope: `rabbitmq`, `os-shell` (still on the old ECR flow, to be
  migrated later), and the two unrelated staged deletions already present
  in the working tree (`images/add-tag-to-engageli-private-ecr-image.sh`,
  `images/redis/copy-image-sources-s3.sh`) — user-confirmed intentional,
  not part of this change.

## How this differs from the `redis` migration

`redis-sentinel` was never previously customized for Engageli's ECR — it's
a stock, freshly-added Bitnami image. So this isn't a *migration*, it's a
first-time CI setup:

- **No docker-compose files exist** for `redis-sentinel` — nothing to
  update.
- **No old `*-build-and-push.sh` script exists** — nothing to delete.
- **The README is the untouched upstream Bitnami doc** — no "Engageli
  notes" section, no registry references at all yet. Instead of rewriting
  ECR references, this adds a new "Engageli notes" section (CI flow) and a
  GHCR-based "Get this image" pull instruction, modeled directly on what
  `redis`'s README now has.

Everything else — registry, tag scheme, workflow shape, concurrency guard,
smoke test — carries over unchanged from the approved `redis` template,
including the `provenance: false` fix the user applied directly to `redis`
after merge (folded into this template from the start).

## Registry & naming

- Image path: `ghcr.io/${{ github.repository }}/redis-sentinel` →
  `ghcr.io/mindw/odd_images/redis-sentinel`.
- Same 4-tag scheme: `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, `latest`,
  derived by sourcing `images/redis-sentinel/current/debian-12/version.sh`
  (which sources `../../../extract-version-bitnami-images.sh ... REDIS_SENTINEL`,
  exporting `REDIS_SENTINEL_APP_VERSION`, `REDIS_SENTINEL_VERSION`, etc. —
  confirmed present and correctly prefixed).
- Confirmed multi-arch viable: the Dockerfile threads `ARG TARGETARCH` the
  same way as `redis`, and arm64 checksums
  (`redis-sentinel-8.8.1-0-linux-arm64-debian-12.tar.gz.sha256`) are
  already committed.

## Workflow file

New file: `.github/workflows/redis-sentinel.yml`, structurally identical
to the final (post-review) `redis.yml`:

```yaml
name: redis-sentinel

on:
  push:
    branches: [main]
    paths:
      - "images/redis-sentinel/**"
      - ".github/workflows/redis-sentinel.yml"
  pull_request:
    paths:
      - "images/redis-sentinel/**"
      - ".github/workflows/redis-sentinel.yml"

concurrency:
  group: redis-sentinel-${{ github.ref }}
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
          source images/redis-sentinel/current/debian-12/version.sh
          IMAGE="ghcr.io/${{ github.repository }}/redis-sentinel"
          MAJOR_MINOR="${REDIS_SENTINEL_APP_VERSION%.*}"
          {
            echo "tags<<EOF"
            echo "${IMAGE}:${REDIS_SENTINEL_VERSION}"
            echo "${IMAGE}:v${REDIS_SENTINEL_APP_VERSION}"
            echo "${IMAGE}:v${MAJOR_MINOR}"
            echo "${IMAGE}:latest"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Build amd64 image for smoke test
        uses: docker/build-push-action@v6
        with:
          context: images/redis-sentinel/current/debian-12
          platforms: linux/amd64
          load: true
          tags: redis-sentinel-smoke-test:local
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke test
        run: |
          docker run -d --name redis-sentinel-smoke -e REDIS_MASTER_HOST=redis redis-sentinel-smoke-test:local
          for i in $(seq 1 30); do
            if docker exec redis-sentinel-smoke redis-cli -p 26379 ping 2>/dev/null | grep -q PONG; then
              echo "Redis Sentinel responded to ping"
              break
            fi
            sleep 1
          done
          docker exec redis-sentinel-smoke redis-cli -p 26379 ping | grep -q PONG
          docker rm -f redis-sentinel-smoke

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
          context: images/redis-sentinel/current/debian-12
          provenance: false
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: ${{ steps.version.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**Smoke test note:** Redis Sentinel listens on port `26379` by default
(`REDIS_SENTINEL_DEFAULT_PORT_NUMBER`), separate from Redis's `6379`.
`REDIS_MASTER_HOST` defaults to `redis` if unset and is not required to
resolve at startup — confirmed in
`rootfs/opt/bitnami/scripts/libredissentinel.sh`: an unresolvable master
host only produces a `warn` ("could not be resolved, this could lead to
connection issues"), it does not fail `setup.sh` (which runs under
`set -o errexit` but never invokes a command that would fail because of
it). So the smoke test can safely start the container with an
unreachable/placeholder `REDIS_MASTER_HOST` and still expect a `PONG`.

### Post-review correction: smoke test env var

Added after the final whole-branch review found the smoke test container
exiting within a second instead of ever answering `ping`: the note above
about `REDIS_MASTER_HOST` not needing to resolve is correct but incomplete
— it never mentions that Redis Sentinel's own startup validation
(`redis_validate` in `libredissentinel.sh`) requires either
`ALLOW_EMPTY_PASSWORD=yes` or a set `REDIS_SENTINEL_PASSWORD`, and exits
`setup.sh` with status 1 if neither is present. That, not
`REDIS_MASTER_HOST`, is why the original `docker run` command's container
died immediately. `REDIS_MASTER_HOST` already defaults to `redis` and
doesn't need to be passed explicitly at all — setting it is harmless but
was never the fix. The workflow's `docker run` now passes both
`-e ALLOW_EMPTY_PASSWORD=yes -e REDIS_MASTER_HOST=redis`.

## README changes

`images/redis-sentinel/README.md` currently has no Engageli customization.
Add, modeled on `redis`'s README:

- A new "Engageli notes" section (before "TL;DR"), describing the CI flow:
  bump `current/debian-12/Dockerfile` → open a PR (CI validates the
  multi-arch build + smoke test) → merge to `main` (CI builds, smoke-tests,
  and pushes all 4 tags to GHCR automatically).
- A new "Get this image" section (or amend the existing bare
  `bitnami/redis-sentinel:latest` references) pointing at
  `ghcr.io/mindw/odd_images/redis-sentinel:latest` and a link to the GHCR
  package page instead of Docker Hub.
- Leave the generic upstream doc content (FIPS, LDAP-equivalent sections,
  env var tables, etc.) untouched — only the registry/CI-facing parts
  change, same discipline as the `redis` rewrite.
- Per user decision carried over from the `redis` work: do **not** add a
  GHCR-package-visibility caveat to the README.

## Testing / verification

Same approach as `redis`: no unit test framework, verification is `yq`
YAML assertions + a real PR run (build-only, both platforms + smoke test)
+ a real push-triggered run after merge (build, smoke test, push all 4
tags, confirm on the GHCR package page).

## Follow-ups (out of scope for this change)

- `rabbitmq` and `os-shell` still need the same migration.
- The two unrelated staged deletions in the working tree are the user's
  own concern, untouched by this change.
