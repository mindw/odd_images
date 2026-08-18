# Design: GitHub Actions build/push for the `redis-cluster` image (GHCR)

## Goal

Apply the same GHCR-based CI template already validated and merged for
`redis`, `redis-sentinel`, `os-shell`, and `rabbitmq` to `redis-cluster`,
the fifth image in this repo — including the non-flaky smoke-test pattern
(loop-success flag + `docker logs` on failure) established after a real
CI failure was found and fixed for `rabbitmq`, `redis`, and
`redis-sentinel`.

## Scope

- In scope: `images/redis-cluster/**` only.
- Out of scope: none remain unaddressed by this template afterward for
  the images currently in this repo.

## Current state

Like `redis-sentinel`, `redis-cluster` was never previously customized
for Engageli — it's freshly added, stock upstream Bitnami sources, still
referencing `docker.io/bitnami/redis-cluster` (Docker Hub), not ECR:

- No "Engageli notes" section exists in the README yet.
- `images/redis-cluster/README.md:11` (TL;DR) has one bare
  `bitnami/redis-cluster:latest` reference to replace. All other
  `bitnami/redis-cluster`/`bitnami/containers` mentions are upstream doc
  links (Helm chart, GitHub source, configuration docs) and stay as-is.
- Two docker-compose files exist, byte-identical:
  `images/redis-cluster/docker-compose.yml` and
  `images/redis-cluster/current/debian-12/docker-compose.yml`. Each
  defines a genuine 6-node Redis Cluster (`redis-node-0` through
  `redis-node-5`), all referencing `image: docker.io/bitnami/redis-cluster:8.8`
  — 6 occurrences per file, 12 total, to become the GHCR path.
- Multi-arch confirmed viable: `ARG TARGETARCH` → `OS_ARCH` threading in
  the Dockerfile, arm64 checksums present for both bundled components
  (`redis-8.8.1-0-linux-arm64-debian-12.tar.gz.sha256`,
  `wait-for-port-1.0.10-14-linux-arm64-debian-12.tar.gz.sha256`).
- `APP_VERSION="8.8.1"` is a real semver (matching plain `redis`), so
  `MAJOR_MINOR` resolves to a genuinely distinct `8.8` tag — no
  `os-shell`-style duplicate-tag quirk.

## Registry & naming

- Image path: `ghcr.io/${{ github.repository }}/redis-cluster` →
  `ghcr.io/mindw/odd_images/redis-cluster`.
- Same 4-tag scheme, derived from
  `images/redis-cluster/current/debian-12/version.sh` (sources
  `extract-version-bitnami-images.sh ... REDIS_CLUSTER`, exporting
  `REDIS_CLUSTER_APP_VERSION`, `REDIS_CLUSTER_VERSION`, etc.).

## Smoke test: single-node run, NOT the full 6-node cluster

The committed docker-compose files describe a genuine multi-node cluster
(`REDIS_CLUSTER_CREATOR=yes` on the last node, `REDIS_NODES` listing all
6 hostnames, cluster formation via `redis-cli --cluster create`). Actually
standing up and validating a 6-node cluster in the smoke-test step would
be a much heavier, higher-value integration test — but it is out of scope
here, matching this template's established purpose: catch "does the
container start and respond," not full functional/integration testing.
The other 4 images' smoke tests are all single-container.

**A real trap found and worked around during design:** the container's
own `--name` is NOT its network hostname (Docker sets the hostname to the
container ID unless `--hostname` is passed or a custom bridge network's
DNS is used). `redis_cluster_validate()` in
`rootfs/opt/bitnami/scripts/librediscluster.sh` requires `REDIS_NODES` to
be non-empty, and `redis_cluster_update_ips()` (called from
`redis-cluster/setup.sh` whenever `REDIS_CLUSTER_DYNAMIC_IPS` is `yes`,
the default) performs a DNS lookup on every entry in `REDIS_NODES` with
`REDIS_DNS_RETRIES` (default 120) retries × 5s sleep — i.e. up to 10
minutes of hanging if the value doesn't resolve. Setting
`REDIS_NODES=<container-name>` to match `--name` **does not work** and
was empirically confirmed to hang (`ps aux` inside the container showed
`setup.sh` stuck in a `sleep 5` loop; `getent hosts <name>` failed to
resolve). The fix: set `REDIS_NODES=127.0.0.1` — the DNS-lookup helper
handles a literal IP without a real lookup, and `REDIS_CLUSTER_CREATOR`
is left at its default (`no`), so `redis-cluster/run.sh` never invokes
`redis_cluster_create` and just execs a plain `redis-server`. Confirmed
locally: container starts, `redis-cli ping` returns `PONG` on the first
attempt.

```yaml
- name: Smoke test
  run: |
    docker run -d --name redis-cluster-smoke -e ALLOW_EMPTY_PASSWORD=yes -e REDIS_NODES=127.0.0.1 redis-cluster-smoke-test:local
    success=false
    for i in $(seq 1 30); do
      if docker exec redis-cluster-smoke redis-cli ping 2>/dev/null | grep -q PONG; then
        echo "Redis Cluster responded to ping"
        success=true
        break
      fi
      sleep 1
    done
    if [ "$success" != "true" ]; then
      docker logs redis-cluster-smoke
      docker rm -f redis-cluster-smoke
      exit 1
    fi
    docker rm -f redis-cluster-smoke
```

This uses the **already-fixed** non-flaky pattern (success flag, no
redundant trailing re-ping, `docker logs` dump on failure) from the
start — the bug that hit `rabbitmq`'s real CI run and was retrofitted
into `redis`/`redis-sentinel` doesn't need to be reintroduced here.

## Workflow file

New file: `.github/workflows/redis-cluster.yml`, same shape as the other
four:

```yaml
name: redis-cluster

on:
  push:
    branches: [main]
    paths:
      - "images/redis-cluster/**"
      - ".github/workflows/redis-cluster.yml"
  pull_request:
    paths:
      - "images/redis-cluster/**"
      - ".github/workflows/redis-cluster.yml"

concurrency:
  group: redis-cluster-${{ github.ref }}
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
          source images/redis-cluster/current/debian-12/version.sh
          IMAGE="ghcr.io/${{ github.repository }}/redis-cluster"
          MAJOR_MINOR="${REDIS_CLUSTER_APP_VERSION%.*}"
          {
            echo "tags<<EOF"
            echo "${IMAGE}:${REDIS_CLUSTER_VERSION}"
            echo "${IMAGE}:v${REDIS_CLUSTER_APP_VERSION}"
            echo "${IMAGE}:v${MAJOR_MINOR}"
            echo "${IMAGE}:latest"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Build amd64 image for smoke test
        uses: docker/build-push-action@v6
        with:
          context: images/redis-cluster/current/debian-12
          platforms: linux/amd64
          load: true
          tags: redis-cluster-smoke-test:local
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke test
        run: |
          docker run -d --name redis-cluster-smoke -e ALLOW_EMPTY_PASSWORD=yes -e REDIS_NODES=127.0.0.1 redis-cluster-smoke-test:local
          success=false
          for i in $(seq 1 30); do
            if docker exec redis-cluster-smoke redis-cli ping 2>/dev/null | grep -q PONG; then
              echo "Redis Cluster responded to ping"
              success=true
              break
            fi
            sleep 1
          done
          if [ "$success" != "true" ]; then
            docker logs redis-cluster-smoke
            docker rm -f redis-cluster-smoke
            exit 1
          fi
          docker rm -f redis-cluster-smoke

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
          context: images/redis-cluster/current/debian-12
          provenance: false
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name == 'push' }}
          tags: ${{ steps.version.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

## README changes

`images/redis-cluster/README.md`:

- Insert a new "Engageli notes" section (before "## TL;DR"), modeled on
  `redis-sentinel`'s (no S3-backup step, since this image — like
  `redis-sentinel`/`os-shell` — was never on the old ECR flow and has no
  `copy-image-sources-s3.sh` for itself).
- Replace the one bare `bitnami/redis-cluster:latest` reference in the
  TL;DR (line 11) with `ghcr.io/mindw/odd_images/redis-cluster:latest`.
- Rewrite the "Get this image" section (currently: "only available to
  Bitnami Secure Images customers") to point at GHCR, matching the
  `redis-sentinel`/`os-shell` pattern.
- Leave all other `bitnami/redis-cluster`/`bitnami/containers` mentions
  untouched — they're upstream doc/Helm-chart links, not registry
  references.
- No GHCR-package-visibility caveat (carried-over decision from all
  prior images).

## Docker Compose file updates

Both `images/redis-cluster/docker-compose.yml` and
`images/redis-cluster/current/debian-12/docker-compose.yml` (byte-identical,
6 `image:` lines each) get all 12 occurrences of
`docker.io/bitnami/redis-cluster:8.8` replaced with
`ghcr.io/mindw/odd_images/redis-cluster:latest`. The 6-node cluster
topology, `REDIS_NODES`/`REDIS_CLUSTER_CREATOR`/`REDIS_CLUSTER_REPLICAS`
env vars, and volumes are otherwise untouched — these compose files
remain a legitimate example of full cluster deployment, unrelated to the
CI smoke test's single-node scope.

## Testing / verification

Same as the other four: `yq`/`grep`/`docker compose config` static
checks, local build+run reproduction of the smoke test (this time
starting from a known-correct, already-battle-tested pattern), a real PR
run, and a real push-triggered run after merge.

## Follow-ups

None outstanding for the currently-known images in this repo.
