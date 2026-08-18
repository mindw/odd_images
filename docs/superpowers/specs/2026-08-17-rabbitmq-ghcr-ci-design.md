# Design: GitHub Actions build/push for the `rabbitmq` image (GHCR)

## Goal

Migrate `rabbitmq` — the last of the four images in this repo — from the
manual AWS-ECR flow to the same GHCR-based CI template already validated
and merged for `redis`, `redis-sentinel`, and `os-shell`.

## Scope

- In scope: `images/rabbitmq/**` only.
- Out of scope: none remain after this — this is the last image.

## Current state

`rabbitmq` is structurally identical to the original `redis` migration: a
real ECR-customized image (Engageli notes, ECR host references
throughout the README), with:

- `images/rabbitmq/rabbitmq-build-and-push.sh` — to delete, fully replaced
  by CI.
- `images/rabbitmq/copy-image-sources-s3.sh` — kept as-is, unrelated to
  the registry.
- `images/rabbitmq/docker-compose.yml` (1 image line) and
  `images/rabbitmq/docker-compose-cluster.yml` (3 image lines, one per
  cluster node) — both reference
  `569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq-dev:v4.3`,
  to be updated to the GHCR path.
- Multi-arch confirmed viable: `ARG TARGETARCH` → `OS_ARCH` threading in
  the Dockerfile, and arm64 checksums present for both bundled components
  (`rabbitmq-4.3.4-0-linux-arm64-debian-12.tar.gz.sha256`,
  `erlang-27.3.4-3-linux-arm64-debian-12.tar.gz.sha256`).
- `images/rabbitmq/README.md` has 17 lines with the ECR host string (all
  the pattern `569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq`)
  and 2 `skopeo` lines — same rewrite pattern as `redis`'s README.

## Registry & naming

- Image path: `ghcr.io/${{ github.repository }}/rabbitmq` →
  `ghcr.io/mindw/odd_images/rabbitmq`.
- Same 4-tag scheme, derived from
  `images/rabbitmq/current/debian-12/version.sh` (sources
  `extract-version-bitnami-images.sh ... RABBITMQ`, exporting
  `RABBITMQ_APP_VERSION`, `RABBITMQ_VERSION`, etc. — `APP_VERSION="4.3.4"`,
  a real semver, so `MAJOR_MINOR` = `4.3` as expected, no `os-shell`-style
  duplicate-tag quirk here).

## Smoke test: RabbitMQ-specific readiness check

RabbitMQ (Erlang/OTP + Mnesia) needs longer to boot than Redis, and unlike
Redis/Redis Sentinel it does **not** need an explicit "allow empty
password" flag — `RABBITMQ_PASSWORD` already defaults to `"bitnami"` and
`RABBITMQ_USERNAME` to `"user"` (confirmed in
`rootfs/opt/bitnami/scripts/rabbitmq-env.sh`), so the container starts
successfully with zero env vars set. The image's own healthcheck script
(`rootfs/opt/bitnami/scripts/rabbitmq/healthcheck.sh`) uses
`rabbitmq-diagnostics -q ping`, so the smoke test reuses exactly that:

```yaml
- name: Smoke test
  run: |
    docker run -d --name rabbitmq-smoke rabbitmq-smoke-test:local
    success=false
    for i in $(seq 1 60); do
      if docker exec rabbitmq-smoke rabbitmq-diagnostics -q --timeout 10 ping; then
        echo "RabbitMQ responded to ping"
        success=true
        break
      fi
      sleep 2
    done
    if [ "$success" != "true" ]; then
      docker logs rabbitmq-smoke
      docker rm -f rabbitmq-smoke
      exit 1
    fi
    docker rm -f rabbitmq-smoke
```

### Post-review correction: dropped the redundant trailing ping

The initial implementation (matching the `redis`/`redis-sentinel` template
verbatim) re-ran `rabbitmq-diagnostics -q ping` a second time,
unconditionally, right after the polling loop broke on success — treated
as a harmless cosmetic duplicate in per-task and final review. The real
PR run on GitHub's hosted runner proved otherwise: the loop's ping
succeeded on iteration 2, but the very next line's independent re-ping
failed 0.7s later (`Failed to connect and authenticate to rabbit@localhost
in 60000 ms`), failing the whole step under `bash -e`. Requiring two
separate connections to a freshly-booted Erlang/Mnesia node to both
succeed, a second apart, is inherently flaky — a transient window right
after boot can pass one connection attempt and reject the next. The fix
tracks loop success with a flag instead of re-asserting it, adds a
`--timeout 10` bound to keep each attempt fast, and dumps `docker logs` on
failure so a real crash is diagnosable in CI output, not just via local
reproduction. The same redundant-trailing-ping pattern still exists,
unfixed, in the merged `redis`/`redis-sentinel` workflows — it didn't
misfire there, but the same latent flake risk applies.

60 iterations × 2s (up to 2 minutes) rather than `redis`'s 30×1s, since
Erlang/Mnesia boot is slower than Redis's. `rabbitmq-diagnostics -q ping`
is checked by exit status directly (`if docker exec ...; then`) rather
than piping to `grep` for a magic string, since the tool's own exit code
is the correct success signal (`-q` suppresses stdout on success).

## Workflow file

New file: `.github/workflows/rabbitmq.yml`, same shape as the other three
(concurrency guard, `provenance: false`, push-gated login):

```yaml
name: rabbitmq

on:
  push:
    branches: [main]
    paths:
      - "images/rabbitmq/**"
      - ".github/workflows/rabbitmq.yml"
  pull_request:
    paths:
      - "images/rabbitmq/**"
      - ".github/workflows/rabbitmq.yml"

concurrency:
  group: rabbitmq-${{ github.ref }}
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
          source images/rabbitmq/current/debian-12/version.sh
          IMAGE="ghcr.io/${{ github.repository }}/rabbitmq"
          MAJOR_MINOR="${RABBITMQ_APP_VERSION%.*}"
          {
            echo "tags<<EOF"
            echo "${IMAGE}:${RABBITMQ_VERSION}"
            echo "${IMAGE}:v${RABBITMQ_APP_VERSION}"
            echo "${IMAGE}:v${MAJOR_MINOR}"
            echo "${IMAGE}:latest"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Build amd64 image for smoke test
        uses: docker/build-push-action@v6
        with:
          context: images/rabbitmq/current/debian-12
          platforms: linux/amd64
          load: true
          tags: rabbitmq-smoke-test:local
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke test
        run: |
          docker run -d --name rabbitmq-smoke rabbitmq-smoke-test:local
          for i in $(seq 1 60); do
            if docker exec rabbitmq-smoke rabbitmq-diagnostics -q ping; then
              echo "RabbitMQ responded to ping"
              break
            fi
            sleep 2
          done
          docker exec rabbitmq-smoke rabbitmq-diagnostics -q ping
          docker rm -f rabbitmq-smoke

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
          context: images/rabbitmq/current/debian-12
          provenance: false
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: ${{ steps.version.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

## README rewrite

`images/rabbitmq/README.md`:

- Rewrite "Engageli notes" (drop the now-deleted-script references
  `add-tag-to-engageli-private-ecr-image.sh`, `aws/misc/ecr.py`,
  `rabbitmq-build-and-push.sh`; describe the CI flow instead; keep the
  `copy-image-sources-s3.sh` backup step, since that script still exists
  for this image, matching `redis`'s pattern).
- Rewrite "Get this image" (pull + skopeo block → GHCR pull + package-page
  link).
- Global sed replace of the remaining 14 `569129334545.../bitnami/rabbitmq`
  references (TL;DR, connecting-to-other-containers examples, the
  standalone Docker Compose YAML snippet embedded in prose, the cluster
  setup snippets, configuration-file example, LDAP example, upgrade
  steps) with `ghcr.io/mindw/odd_images/rabbitmq`.
- No GHCR-package-visibility caveat (carried-over decision).

## Docker Compose file updates

- `images/rabbitmq/docker-compose.yml`: 1 `image:` line →
  `ghcr.io/mindw/odd_images/rabbitmq:latest`.
- `images/rabbitmq/docker-compose-cluster.yml`: 3 `image:` lines (stats,
  queue-disc1, queue-ram1) → same GHCR path, `latest` tag.

## Script cleanup

- Delete `images/rabbitmq/rabbitmq-build-and-push.sh`.
- Keep `images/rabbitmq/copy-image-sources-s3.sh` (unrelated to registry).

## Testing / verification

Same as the other three: `yq` YAML assertions, `grep`/`docker compose
config` checks, a real PR run (build-only + smoke test, both platforms),
a real push-triggered run after merge, with local build+run reproduction
of the smoke test during final review (per the lesson learned from the
`redis-sentinel` migration, where a copy-pasted env var bug was only
caught by actually running the container).

## Follow-ups

None — this is the last of the four images. All Bitnami-derived images in
this repo will be on the same GHCR-based CI pattern after this merges.
