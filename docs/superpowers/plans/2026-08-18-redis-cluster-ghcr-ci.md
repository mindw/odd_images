# Redis Cluster GHCR CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds `redis-cluster` for `linux/amd64` and `linux/arm64`, smoke-tests it as a single node, and pushes it to GHCR whenever its source changes — the fifth image on this repo's established template, using the already-fixed non-flaky smoke-test pattern from the start.

**Architecture:** One workflow file (`.github/workflows/redis-cluster.yml`), same shape as the other four. The smoke test runs the container as a standalone node (`REDIS_NODES=127.0.0.1`, `REDIS_CLUSTER_CREATOR` left at its default `no`) rather than forming the full 6-node cluster the compose files describe — matching this template's "does it start and respond" scope, not full integration testing.

**Tech Stack:** GitHub Actions, `docker/setup-qemu-action@v3`, `docker/setup-buildx-action@v3`, `docker/login-action@v3`, `docker/build-push-action@v6`. Verification: `yq`, `grep`, `docker compose config`, local build+run reproduction, a real PR run, a real push-triggered run.

Full design/rationale: `docs/superpowers/specs/2026-08-18-redis-cluster-ghcr-ci-design.md`.

## Global Constraints

- **Image path:** `ghcr.io/${{ github.repository }}/redis-cluster` (built from context, never hardcoded in the workflow).
- **Tag scheme, exactly 4, pushed together on `push` to `main`:** `${IMAGE}:${REDIS_CLUSTER_VERSION}`, `${IMAGE}:v${REDIS_CLUSTER_APP_VERSION}`, `${IMAGE}:v${MAJOR_MINOR}`, `${IMAGE}:latest`.
- **`version.sh` must be `source`d, never executed.**
- **Smoke test MUST set `REDIS_NODES=127.0.0.1`, not a hostname/container name.** A hostname (even one matching `--name`) does not resolve inside the container (Docker's default hostname is the container ID, not `--name`) and causes `redis_cluster_update_ips`'s DNS-lookup retry loop to hang for up to 10 minutes (empirically confirmed during design). `127.0.0.1` is a literal IP and resolves immediately. Do not "simplify" this to a hostname.
- **Smoke test MUST use the non-flaky pattern**: a `success=false`/`success=true` flag tracked across the polling loop, `docker logs <container> && docker rm -f <container> && exit 1` on failure, and NO redundant unconditional re-ping after the loop. This is not optional polish — an earlier version of this exact pattern (redundant trailing re-ping) caused a real CI failure in `rabbitmq`'s first PR run and was retrofitted into `redis`/`redis-sentinel` afterward. Build it correctly from the start here.
- **In scope:** `images/redis-cluster/**` and `.github/workflows/redis-cluster.yml` only.
- **No unit test framework exists in this repo.** Verification is `yq`/`grep`/`docker compose config` plus local reproduction and a real GitHub Actions run.
- **No per-task commits.** Only the commit task commits, once. Never `git add -A` or `git add .` — stage only the exact file list given.
- **Do not add a GHCR-package-visibility caveat to the README** — carried-over decision from all four prior images.
- **The push/PR/watch task is executed autonomously** (auto mode is active for this session) — no confirmation checkpoint before pushing/opening the PR. **Merging the resulting PR is still left to the user, never the agent.**

---

### Task 1: Add the `redis-cluster` GitHub Actions workflow

**Files:**
- Create: `.github/workflows/redis-cluster.yml`

- [ ] **Step 1: Confirm the file doesn't exist yet**

Run: `yq '.on.pull_request.paths' .github/workflows/redis-cluster.yml`
Expected: FAIL — `Error: no such file or directory`

- [ ] **Step 2: Write the workflow file**

Create `.github/workflows/redis-cluster.yml` with exactly this content:

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

- [ ] **Step 3: Validate the YAML parses and the key fields are correct**

```bash
yq eval '.' .github/workflows/redis-cluster.yml > /dev/null && echo VALID
yq '.on.pull_request.paths' .github/workflows/redis-cluster.yml
yq '.concurrency.group' .github/workflows/redis-cluster.yml
yq '.permissions.packages' .github/workflows/redis-cluster.yml
yq '.jobs.build.steps[] | select(.name == "Smoke test") | .run' .github/workflows/redis-cluster.yml
yq '.jobs.build.steps[-1].with.provenance' .github/workflows/redis-cluster.yml
```

Expected, in order:
```
VALID
- images/redis-cluster/**
- .github/workflows/redis-cluster.yml
redis-cluster-${{ github.ref }}
write
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
false
```

- [ ] **Step 4: Reproduce the smoke test locally**

```bash
docker build -t redis-cluster-smoke-test:local images/redis-cluster/current/debian-12
docker run -d --name redis-cluster-smoke-verify -e ALLOW_EMPTY_PASSWORD=yes -e REDIS_NODES=127.0.0.1 redis-cluster-smoke-test:local
docker exec redis-cluster-smoke-verify redis-cli ping
docker rm -f redis-cluster-smoke-verify
docker rmi redis-cluster-smoke-test:local
```
Expected: `redis-cli ping` prints `PONG`. Do NOT use a hostname/container-name value for `REDIS_NODES` — it will hang (see Global Constraints).

---

### Task 2: Add Engageli/GHCR content to `images/redis-cluster/README.md`

**Files:**
- Modify: `images/redis-cluster/README.md`

- [ ] **Step 1: Confirm the check currently fails**

```bash
grep -c "ghcr.io/mindw/odd_images" images/redis-cluster/README.md; grep -c "Engageli notes" images/redis-cluster/README.md
```
Expected: `0`, `0`.

- [ ] **Step 2: Insert a new "Engageli notes" section before "## TL;DR"**

Old (the file starts):
```markdown
# Bitnami Secure Image for Redis&reg; Cluster

> Redis&reg; is an open source, scalable, distributed in-memory cache for applications. It can be used to store and serve data in the form of strings, hashes, lists, sets and sorted sets.

[Overview of Redis&reg; Cluster](https://redis.io)
Disclaimer: Redis is a registered trademark of Redis Ltd. Any rights therein are reserved to Redis Ltd. Any use by Bitnami is for referential purposes only and does not indicate any sponsorship, endorsement, or affiliation between Redis Ltd.

## TL;DR
```

New:
```markdown
# Bitnami Secure Image for Redis&reg; Cluster

> Redis&reg; is an open source, scalable, distributed in-memory cache for applications. It can be used to store and serve data in the form of strings, hashes, lists, sets and sorted sets.

[Overview of Redis&reg; Cluster](https://redis.io)
Disclaimer: Redis is a registered trademark of Redis Ltd. Any rights therein are reserved to Redis Ltd. Any use by Bitnami is for referential purposes only and does not indicate any sponsorship, endorsement, or affiliation between Redis Ltd.

## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/redis-cluster)
2. Bump `current/debian-12/Dockerfile` to the new version
3. Open a pull request — the `redis-cluster` GitHub Actions workflow builds the image for `linux/amd64` and `linux/arm64` and runs a smoke test to confirm it still starts. No image is pushed for pull requests.
4. Once the PR is merged to `main`, the same workflow builds, smoke-tests, and pushes the image to GHCR, tagged as `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, and `latest` in one step.

## TL;DR
```

- [ ] **Step 3: Replace the TL;DR line**

Old:
```markdown
docker run --name redis-cluster -e ALLOW_EMPTY_PASSWORD=yes bitnami/redis-cluster:latest
```
New:
```markdown
docker run --name redis-cluster -e ALLOW_EMPTY_PASSWORD=yes ghcr.io/mindw/odd_images/redis-cluster:latest
```

- [ ] **Step 4: Rewrite the "Get this image" section**

Old:
```markdown
## Get this image

The Bitnami Redis&reg; Cluster Docker image is only available to [Bitnami Secure Images](https://bitnami.com) customers.
```

New:
```markdown
## Get this image

The recommended way to get the Redis Cluster Docker image is to pull the prebuilt image
from the Engageli GitHub Container Registry.

```console
docker pull ghcr.io/mindw/odd_images/redis-cluster:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of
available versions on the [package page](https://github.com/mindw/odd_images/pkgs/container/odd_images%2Fredis-cluster).

```console
docker pull ghcr.io/mindw/odd_images/redis-cluster:[TAG]
```
```

- [ ] **Step 5: Re-run the check and confirm it now passes**

```bash
grep -c "ghcr.io/mindw/odd_images" images/redis-cluster/README.md; grep -c "Engageli notes" images/redis-cluster/README.md
```
Expected: `3` (1 from Step 3 + 2 from Step 4), `1`.

---

### Task 3: Update the docker-compose files

**Files:**
- Modify: `images/redis-cluster/docker-compose.yml`
- Modify: `images/redis-cluster/current/debian-12/docker-compose.yml`

- [ ] **Step 1: Confirm the check currently fails**

```bash
grep -c "ghcr.io/mindw/odd_images/redis-cluster" images/redis-cluster/docker-compose.yml images/redis-cluster/current/debian-12/docker-compose.yml
```
Expected: `0` for both.

- [ ] **Step 2: Replace all 6 occurrences in each file**

Both files are byte-identical. In each, replace every occurrence of:
```yaml
    image: docker.io/bitnami/redis-cluster:8.8
```
with:
```yaml
    image: ghcr.io/mindw/odd_images/redis-cluster:latest
```

Use sed for both files (6 occurrences each, all identical, no other content to preserve differently per-line):
```bash
sed -i 's#docker\.io/bitnami/redis-cluster:8\.8#ghcr.io/mindw/odd_images/redis-cluster:latest#g' images/redis-cluster/docker-compose.yml
sed -i 's#docker\.io/bitnami/redis-cluster:8\.8#ghcr.io/mindw/odd_images/redis-cluster:latest#g' images/redis-cluster/current/debian-12/docker-compose.yml
```

- [ ] **Step 3: Validate and re-run the check**

```bash
docker compose -f images/redis-cluster/docker-compose.yml config -q && echo "docker-compose.yml OK"
docker compose -f images/redis-cluster/current/debian-12/docker-compose.yml config -q && echo "nested docker-compose.yml OK"
grep -c "ghcr.io/mindw/odd_images/redis-cluster" images/redis-cluster/docker-compose.yml images/redis-cluster/current/debian-12/docker-compose.yml
grep -c "docker.io/bitnami/redis-cluster" images/redis-cluster/docker-compose.yml images/redis-cluster/current/debian-12/docker-compose.yml
```
Expected: both `OK` lines print; the ghcr grep prints `6`, `6`; the docker.io grep prints `0`, `0`.

---

### Task 4: Review and single commit (spec + plan + implementation)

- [ ] **Step 1: Show the diff**

```bash
git status --porcelain -- docs/ .github/ images/redis-cluster/
git diff -- images/redis-cluster/
```

Confirm this is exactly the expected file list: 2 new docs, the new workflow, the README change, and the 2 compose file changes — nothing from `redis`, `redis-sentinel`, `os-shell`, or `rabbitmq`.

- [ ] **Step 2: Stage exactly these paths (never `-A` or `.`)**

```bash
git add \
  docs/superpowers/specs/2026-08-18-redis-cluster-ghcr-ci-design.md \
  docs/superpowers/plans/2026-08-18-redis-cluster-ghcr-ci.md \
  .github/workflows/redis-cluster.yml \
  images/redis-cluster/README.md \
  images/redis-cluster/docker-compose.yml \
  images/redis-cluster/current/debian-12/docker-compose.yml
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add GitHub Actions workflow to build and push redis-cluster to GHCR

Same template already validated for redis, redis-sentinel, os-shell,
and rabbitmq: multi-arch (amd64+arm64) build, a single-node smoke test
(the committed docker-compose files describe a genuine 6-node cluster,
out of scope for this smoke test), and push to GHCR on merge to main.
Uses the non-flaky smoke-test pattern (success flag, docker logs on
failure) from the start, learned from a real CI failure in rabbitmq's
initial rollout.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
git show --stat HEAD
```
Expected: exactly the 6 staged paths.

---

### Task 5: Push, open a PR, and watch the real workflow run

Executed autonomously (auto mode active for this session) — no
confirmation checkpoint before pushing/opening the PR. Merging is still
left to the user.

- [ ] **Step 1: Check origin/main sync, push a branch**

```bash
git fetch origin main --quiet
git rev-list --left-right --count origin/main...main
```
If not `0	0`, fast-forward-push `main` first.

```bash
git push origin HEAD:redis-cluster-ghcr-ci
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --head redis-cluster-ghcr-ci --title "Add GHCR build/push workflow for redis-cluster" --body "$(cat <<'EOF'
## Summary
- Add .github/workflows/redis-cluster.yml: multi-arch (amd64+arm64)
  build + single-node smoke test on every PR touching
  images/redis-cluster/**, build+push to
  ghcr.io/mindw/odd_images/redis-cluster on merge to main.
- Add Engageli notes and GHCR pull instructions to
  images/redis-cluster/README.md (previously stock upstream doc, never
  customized for this repo's registry).
- Update both docker-compose files' 6-node cluster definitions to
  reference GHCR instead of Docker Hub.
- Fifth image on this repo's GHCR CI template, using the non-flaky
  smoke-test pattern from the start.

## Test plan
- [ ] This PR's own `redis-cluster` workflow run builds successfully for
      both linux/amd64 and linux/arm64, and the smoke test passes
      (build-only, no push, since this is a PR).
- [ ] After merge, confirm the push-triggered run succeeds and all 4 tags
      appear on the GHCR package page.
EOF
)"
```

- [ ] **Step 3: Watch the real run and report the actual outcome**

```bash
gh run list --branch redis-cluster-ghcr-ci --limit 1
gh run watch --exit-status
```

- [ ] **Step 4: Leave the merge to the user**

Do not merge the PR.
