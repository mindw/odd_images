# Redis Sentinel GHCR CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds the `redis-sentinel` image for `linux/amd64` and `linux/arm64`, smoke-tests it, and pushes it to GHCR whenever its source changes — the same template already validated and merged for `redis`, applied here for the first time (this image was never on the old ECR flow).

**Architecture:** One workflow file (`.github/workflows/redis-sentinel.yml`), single job, identical shape to the final (post-review) `redis.yml`: QEMU + buildx, source `version.sh`, amd64 smoke test before push, concurrency guard, `provenance: false`.

**Tech Stack:** Same as the `redis` plan — GitHub Actions, `docker/setup-qemu-action@v3`, `docker/setup-buildx-action@v3`, `docker/login-action@v3`, `docker/build-push-action@v6`. Verification: `yq`, `grep`, a real PR run, a real push-triggered run.

Full design/rationale: `docs/superpowers/specs/2026-08-16-redis-sentinel-ghcr-ci-design.md`.

## Global Constraints

- **Image path:** `ghcr.io/${{ github.repository }}/redis-sentinel` (built from context, never hardcoded in the workflow itself).
- **Tag scheme, exactly 4, pushed together on `push` to `main`:** `${IMAGE}:${REDIS_SENTINEL_VERSION}`, `${IMAGE}:v${REDIS_SENTINEL_APP_VERSION}`, `${IMAGE}:v${MAJOR_MINOR}`, `${IMAGE}:latest`.
- **`version.sh` must be `source`d, never executed.**
- **In scope:** `images/redis-sentinel/**` and `.github/workflows/redis-sentinel.yml` only. Do not touch `redis`, `rabbitmq`, `os-shell`, or the two unrelated staged deletions already present in the repo (`images/add-tag-to-engageli-private-ecr-image.sh`, `images/redis/copy-image-sources-s3.sh`) — user-confirmed intentional and out of scope.
- **No unit test framework exists in this repo.** Verification is `yq` YAML assertions, `grep` reference checks, and a real GitHub Actions run — shown to pass, not assumed.
- **No per-task commits.** Only Task 3 commits, once, after the user reviews the diff. Never `git add -A` or `git add .` — stage only the exact file list given in Task 3.
- **Task 4 (push branch, open PR, watch the real run) requires an explicit go-ahead at execution time before pushing/opening the PR** — a visible, remote action. Merging the resulting PR is left to the user, not the agent.
- **Do not add a GHCR-package-visibility caveat to the README** — the user explicitly declined this for `redis` and the same call carries over here.

---

### Task 1: Add the `redis-sentinel` GitHub Actions workflow

**Files:**
- Create: `.github/workflows/redis-sentinel.yml`

- [ ] **Step 1: Confirm the file doesn't exist yet**

Run: `yq '.on.pull_request.paths' .github/workflows/redis-sentinel.yml`
Expected: FAIL — `Error: no such file or directory`

- [ ] **Step 2: Write the workflow file**

Create `.github/workflows/redis-sentinel.yml` with exactly this content:

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

- [ ] **Step 3: Validate the YAML parses and the key fields are correct**

```bash
yq eval '.' .github/workflows/redis-sentinel.yml > /dev/null && echo VALID
yq '.on.pull_request.paths' .github/workflows/redis-sentinel.yml
yq '.concurrency.group' .github/workflows/redis-sentinel.yml
yq '.permissions.packages' .github/workflows/redis-sentinel.yml
yq '.jobs.build.steps[-1].with.platforms' .github/workflows/redis-sentinel.yml
yq '.jobs.build.steps[-1].with.provenance' .github/workflows/redis-sentinel.yml
```

Expected, in order:
```
VALID
- images/redis-sentinel/**
- .github/workflows/redis-sentinel.yml
redis-sentinel-${{ github.ref }}
write
linux/amd64,linux/arm64
false
```

---

### Task 2: Add Engageli/GHCR content to `images/redis-sentinel/README.md`

**Files:**
- Modify: `images/redis-sentinel/README.md`

- [ ] **Step 1: Confirm the check currently fails**

```bash
grep -c "ghcr.io/mindw/odd_images" images/redis-sentinel/README.md; grep -c "Engageli notes" images/redis-sentinel/README.md
```
Expected: `0`, `0`.

- [ ] **Step 2: Insert a new "Engageli notes" section before "## TL;DR"**

Old (lines 6-8):
```markdown
Disclaimer: Redis is a registered trademark of Redis Ltd. Any rights therein are reserved to Redis Ltd. Any use by Bitnami is for referential purposes only and does not indicate any sponsorship, endorsement, or affiliation between Redis Ltd.

## TL;DR
```

New:
```markdown
Disclaimer: Redis is a registered trademark of Redis Ltd. Any rights therein are reserved to Redis Ltd. Any use by Bitnami is for referential purposes only and does not indicate any sponsorship, endorsement, or affiliation between Redis Ltd.

## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/redis-sentinel)
2. Bump `current/debian-12/Dockerfile` to the new version
3. Open a pull request — the `redis-sentinel` GitHub Actions workflow builds the image for `linux/amd64` and `linux/arm64` and runs a smoke test to confirm it still starts. No image is pushed for pull requests.
4. Once the PR is merged to `main`, the same workflow builds, smoke-tests, and pushes the image to GHCR, tagged as `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, and `latest` in one step.

## TL;DR
```

- [ ] **Step 3: Rewrite the "Get this image" section**

Old (lines 39-41):
```markdown
## Get this image

The Bitnami Redis&reg; Sentinel Docker image is only available to [Bitnami Secure Images](https://bitnami.com) customers.
```

New:
```markdown
## Get this image

The recommended way to get the Redis Sentinel Docker image is to pull the prebuilt image
from the Engageli GitHub Container Registry.

```console
docker pull ghcr.io/mindw/odd_images/redis-sentinel:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of
available versions on the [package page](https://github.com/mindw/odd_images/pkgs/container/odd_images%2Fredis-sentinel).

```console
docker pull ghcr.io/mindw/odd_images/redis-sentinel:[TAG]
```
```

- [ ] **Step 4: Replace the remaining bare Docker Hub references**

Two distinct substitutions (5 total lines: 11, 67, 78, 160, 177 in the
original file — do not touch line 128's env var name or line 163's
upstream doc link, which merely contain the substring):

```bash
sed -i 's#bitnami/redis-sentinel:latest#ghcr.io/mindw/odd_images/redis-sentinel:latest#g' images/redis-sentinel/README.md
sed -i 's#bitnami/redis:latest#ghcr.io/mindw/odd_images/redis:latest#g' images/redis-sentinel/README.md
```

- [ ] **Step 5: Re-run the check and confirm it now passes**

```bash
grep -c "ghcr.io/mindw/odd_images" images/redis-sentinel/README.md
grep -c "Engageli notes" images/redis-sentinel/README.md
grep -c "bitnami/redis-sentinel:latest\|bitnami/redis:latest" images/redis-sentinel/README.md
```
Expected: `7` (2 from Step 3 + 5 from Step 4), `1`, `0`.

---

### Task 3: Review and single commit (spec + plan + implementation)

- [ ] **Step 1: Show the user the full diff for review**

```bash
git status --porcelain -- docs/ .github/ images/redis-sentinel/README.md
git diff -- images/redis-sentinel/README.md
```

Confirm with the user this is exactly the expected file list: the 2 new
docs, the new workflow, and the README change — nothing from `redis`,
`rabbitmq`, `os-shell`, or the two unrelated staged deletions.

- [ ] **Step 2: Stage exactly these paths (never `-A` or `.`)**

```bash
git add \
  docs/superpowers/specs/2026-08-16-redis-sentinel-ghcr-ci-design.md \
  docs/superpowers/plans/2026-08-16-redis-sentinel-ghcr-ci.md \
  .github/workflows/redis-sentinel.yml \
  images/redis-sentinel/README.md
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add GitHub Actions workflow to build and push redis-sentinel to GHCR

Same template already validated for redis: multi-arch (amd64+arm64)
build, amd64 smoke test, and push to GHCR on merge to main; build-only
validation on every PR touching images/redis-sentinel/**.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
git show --stat HEAD
```
Expected: exactly the 4 staged paths, nothing else.

---

### Task 4: Push, open a PR, and watch the real workflow run (requires explicit go-ahead)

**This pushes a branch and opens a real pull request against
`github.com/mindw/odd_images`. Do not run these steps without the user
explicitly confirming at execution time.**

- [ ] **Step 1: Ask the user for explicit go-ahead**

Do not proceed until the user says yes.

- [ ] **Step 2: Create a branch and push it**

```bash
git checkout -b redis-sentinel-ghcr-ci
git push -u origin redis-sentinel-ghcr-ci
```

(Check first whether `origin/main` is behind local `main` — if so, fast-forward-push `main` first, same issue hit during the `redis` work, so the PR diff doesn't bundle in unrelated prior commits.)

- [ ] **Step 3: Open the PR**

```bash
gh pr create --title "Add GHCR build/push workflow for redis-sentinel" --body "$(cat <<'EOF'
## Summary
- Add .github/workflows/redis-sentinel.yml: multi-arch (amd64+arm64) build
  + amd64 smoke test on every PR touching images/redis-sentinel/**,
  build+push to ghcr.io/mindw/odd_images/redis-sentinel on merge to main.
- Add Engageli notes and GHCR pull instructions to
  images/redis-sentinel/README.md (previously stock upstream doc, never
  customized for this repo's registry).

## Test plan
- [ ] This PR's own `redis-sentinel` workflow run builds successfully for
      both linux/amd64 and linux/arm64, and the smoke test passes
      (build-only, no push, since this is a PR).
- [ ] After merge, confirm the push-triggered run succeeds and all 4 tags
      appear on the GHCR package page.
EOF
)"
```

- [ ] **Step 4: Watch the real run and report the actual outcome**

```bash
gh run list --branch redis-sentinel-ghcr-ci --limit 1
gh run watch --exit-status
```

Report the actual result — do not report success until `gh run watch` has
shown it.

- [ ] **Step 5: Leave the merge to the user**

Do not merge the PR.
