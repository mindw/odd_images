# RabbitMQ GHCR CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `rabbitmq` — the last of the four images in this repo — to the same GHCR-based CI template already validated and merged for `redis`, `redis-sentinel`, and `os-shell`.

**Architecture:** One workflow file (`.github/workflows/rabbitmq.yml`), same shape as the other three, with a RabbitMQ-specific smoke test using `rabbitmq-diagnostics -q ping` (the image's own healthcheck command) and a longer poll window (60×2s) since Erlang/Mnesia boot is slower than Redis.

**Tech Stack:** Same as the other three plans — GitHub Actions, `docker/setup-qemu-action@v3`, `docker/setup-buildx-action@v3`, `docker/login-action@v3`, `docker/build-push-action@v6`. Verification: `yq`, `grep`, `docker compose config`, a real PR run, a real push-triggered run, and local build+run reproduction of the smoke test during final review.

Full design/rationale: `docs/superpowers/specs/2026-08-17-rabbitmq-ghcr-ci-design.md`.

## Global Constraints

- **Image path:** `ghcr.io/${{ github.repository }}/rabbitmq` (built from context, never hardcoded in the workflow).
- **Tag scheme, exactly 4, pushed together on `push` to `main`:** `${IMAGE}:${RABBITMQ_VERSION}`, `${IMAGE}:v${RABBITMQ_APP_VERSION}`, `${IMAGE}:v${MAJOR_MINOR}`, `${IMAGE}:latest}`.
- **`version.sh` must be `source`d, never executed.**
- **RabbitMQ needs no explicit "allow empty password" env var** — `RABBITMQ_PASSWORD` defaults to `"bitnami"`, `RABBITMQ_USERNAME` to `"user"` — do not add one; a bare `docker run -d --name rabbitmq-smoke rabbitmq-smoke-test:local` with no env vars is correct.
- **In scope:** `images/rabbitmq/**` and `.github/workflows/rabbitmq.yml` only.
- **No unit test framework exists in this repo.** Verification is `yq`/`grep`/`docker compose config` plus a real GitHub Actions run and local reproduction.
- **No per-task commits.** Only the commit task commits, once. Never `git add -A` or `git add .` — stage only the exact file list given.
- **Keep `images/rabbitmq/copy-image-sources-s3.sh`** — unrelated to the registry, do not delete it (unlike `rabbitmq-build-and-push.sh`, which IS deleted).
- **Do not add a GHCR-package-visibility caveat to the README** — carried-over decision from the other three images.
- **The push/PR/watch task is executed autonomously** (per explicit user "auto mode" instruction) — no confirmation checkpoint before pushing/opening the PR. **Merging the resulting PR is still left to the user, never the agent.**

---

### Task 1: Add the `rabbitmq` GitHub Actions workflow

**Files:**
- Create: `.github/workflows/rabbitmq.yml`

- [ ] **Step 1: Confirm the file doesn't exist yet**

Run: `yq '.on.pull_request.paths' .github/workflows/rabbitmq.yml`
Expected: FAIL — `Error: no such file or directory`

- [ ] **Step 2: Write the workflow file**

Create `.github/workflows/rabbitmq.yml` with exactly this content:

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

- [ ] **Step 3: Validate the YAML parses and the key fields are correct**

```bash
yq eval '.' .github/workflows/rabbitmq.yml > /dev/null && echo VALID
yq '.on.pull_request.paths' .github/workflows/rabbitmq.yml
yq '.concurrency.group' .github/workflows/rabbitmq.yml
yq '.permissions.packages' .github/workflows/rabbitmq.yml
yq '.jobs.build.steps[] | select(.name == "Smoke test") | .run' .github/workflows/rabbitmq.yml
yq '.jobs.build.steps[-1].with.provenance' .github/workflows/rabbitmq.yml
```

Expected, in order:
```
VALID
- images/rabbitmq/**
- .github/workflows/rabbitmq.yml
rabbitmq-${{ github.ref }}
write
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
false
```

---

### Task 2: Rewrite `images/rabbitmq/README.md`

**Files:**
- Modify: `images/rabbitmq/README.md`

- [ ] **Step 1: Confirm the check currently fails**

```bash
grep -c "ghcr.io/mindw/odd_images" images/rabbitmq/README.md; grep -c "569129334545" images/rabbitmq/README.md; grep -c "skopeo" images/rabbitmq/README.md
```
Expected: `0`, `17`, `2`.

- [ ] **Step 2: Rewrite the "Engageli notes" section (lines 10-34, up to but not including `## TL;DR`)**

Old:
```markdown
## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/rabbitmq)
2. backup image source files using: `AWS_PROFILE=shared_assets ./copy-image-sources-s3.sh`
3. Build and push using `AWS_PROFILE=shared_assets ./rabbitmq-build-and-push.sh`
4. Deploy on a dev cluster
5. Once merged, promote tag as `latest` and VERSION latest :
   ```
   . current/debian-12/version.sh
   # add "latest"
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/rabbitmq ${RABBITMQ_VERSION}
   # add VERSION latest
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/rabbitmq ${RABBITMQ_VERSION} v${RABBITMQ_APP_VERSION}
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/rabbitmq ${RABBITMQ_VERSION} v${RABBITMQ_APP_VERSION%.*} 
   ```
6. Once merged, propagate image to `dev` and `prod` repos using `aws/misc/ecr.py`.
   ```
   . current/debian-12/version.sh 
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${RABBITMQ_VERSION} --ci -s dev -d test -r bitnami/rabbitmq
   # and to production once the PR is merged
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${RABBITMQ_VERSION} --ci -r bitnami/rabbitmq
   ```
```

New:
```markdown
## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/rabbitmq)
2. Backup image source files using: `AWS_PROFILE=shared_assets ./copy-image-sources-s3.sh`
3. Bump `current/debian-12/Dockerfile` to the new version
4. Open a pull request — the `rabbitmq` GitHub Actions workflow builds the image for `linux/amd64` and `linux/arm64` and runs a smoke test to confirm it still starts. No image is pushed for pull requests.
5. Once the PR is merged to `main`, the same workflow builds, smoke-tests, and pushes the image to GHCR, tagged as `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, and `latest` in one step.
```

- [ ] **Step 3: Rewrite the "Get this image" section (lines 43-59)**

Old:
```markdown
## Get this image

The recommended way to get the Bitnami RabbitMQ Docker Image is to pull the prebuilt image
from the Engageli private ECR repository.

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of 
available versions using `skopeo`:
```
skopeo list-tags docker://569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq | jq .Tags[] -r
```

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq:[TAG]
```
```

New:
```markdown
## Get this image

The recommended way to get the Bitnami RabbitMQ Docker Image is to pull the prebuilt image
from the Engageli GitHub Container Registry.

```console
docker pull ghcr.io/mindw/odd_images/rabbitmq:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of
available versions on the [package page](https://github.com/mindw/odd_images/pkgs/container/odd_images%2Frabbitmq).

```console
docker pull ghcr.io/mindw/odd_images/rabbitmq:[TAG]
```
```

- [ ] **Step 4: Replace the remaining 14 ECR-host references**

These are the remaining lines containing the literal substring
`569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq`, outside
the two sections already rewritten above (originally lines 38, 92, 102,
118, 249, 268, 284, 313, 323, 332, 367, 438, 466, 509 — in the TL;DR,
"Connecting to other containers", the embedded Docker Compose YAML
snippet, the cluster-setup snippets, the custom-config example, the LDAP
example, and the upgrade steps). Run:

```bash
sed -i 's#569129334545\.dkr\.ecr\.us-east-1\.amazonaws\.com/bitnami/rabbitmq#ghcr.io/mindw/odd_images/rabbitmq#g' images/rabbitmq/README.md
```

- [ ] **Step 5: Re-run the check and confirm it now passes**

```bash
grep -c "ghcr.io/mindw/odd_images" images/rabbitmq/README.md; grep -c "569129334545" images/rabbitmq/README.md; grep -c "skopeo" images/rabbitmq/README.md
```
Expected: `16` (2 from Step 3 + 14 from Step 4), `0`, `0`.

---

### Task 3: Update the docker-compose files

**Files:**
- Modify: `images/rabbitmq/docker-compose.yml`
- Modify: `images/rabbitmq/docker-compose-cluster.yml`

- [ ] **Step 1: Confirm the check currently fails**

```bash
grep -rc "ghcr.io/mindw/odd_images/rabbitmq" images/rabbitmq/docker-compose.yml images/rabbitmq/docker-compose-cluster.yml
```
Expected: `0` for both.

- [ ] **Step 2: Fix `images/rabbitmq/docker-compose.yml`**

Old:
```yaml
    image: 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq-dev:v4.3
```
New:
```yaml
    image: ghcr.io/mindw/odd_images/rabbitmq:latest
```

- [ ] **Step 3: Fix `images/rabbitmq/docker-compose-cluster.yml` (3 occurrences: stats, queue-disc1, queue-ram1)**

Replace all 3 occurrences of:
```yaml
    image: 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/rabbitmq-dev:v4.3
```
with:
```yaml
    image: ghcr.io/mindw/odd_images/rabbitmq:latest
```

- [ ] **Step 4: Validate and re-run the check**

```bash
docker compose -f images/rabbitmq/docker-compose.yml config -q && echo "docker-compose.yml OK"
docker compose -f images/rabbitmq/docker-compose-cluster.yml config -q && echo "docker-compose-cluster.yml OK"
grep -rc "ghcr.io/mindw/odd_images/rabbitmq" images/rabbitmq/docker-compose.yml images/rabbitmq/docker-compose-cluster.yml
grep -rc "569129334545" images/rabbitmq/docker-compose.yml images/rabbitmq/docker-compose-cluster.yml
```
Expected: both `OK` lines print; the ghcr grep prints `1`, `3` (in file order); the ECR grep prints `0` for both.

---

### Task 4: Remove the obsolete ECR build/push script

**Files:**
- Delete: `images/rabbitmq/rabbitmq-build-and-push.sh`

- [ ] **Step 1: Confirm it exists before deleting**

Run: `test -f images/rabbitmq/rabbitmq-build-and-push.sh && echo EXISTS`
Expected: `EXISTS`

- [ ] **Step 2: Delete it**

```bash
rm images/rabbitmq/rabbitmq-build-and-push.sh
```

- [ ] **Step 3: Confirm it's gone and its sibling script is untouched**

```bash
test -f images/rabbitmq/rabbitmq-build-and-push.sh && echo STILL_THERE || echo GONE
test -f images/rabbitmq/copy-image-sources-s3.sh && echo COPY_SCRIPT_STILL_PRESENT
```
Expected: `GONE`, then `COPY_SCRIPT_STILL_PRESENT`.

---

### Task 5: Review and single commit (spec + plan + implementation)

- [ ] **Step 1: Show the diff**

```bash
git status --porcelain -- docs/ .github/ images/rabbitmq/README.md images/rabbitmq/docker-compose.yml images/rabbitmq/docker-compose-cluster.yml images/rabbitmq/rabbitmq-build-and-push.sh
```

- [ ] **Step 2: Stage exactly these paths (never `-A` or `.`)**

```bash
git add \
  docs/superpowers/specs/2026-08-17-rabbitmq-ghcr-ci-design.md \
  docs/superpowers/plans/2026-08-17-rabbitmq-ghcr-ci.md \
  .github/workflows/rabbitmq.yml \
  images/rabbitmq/README.md \
  images/rabbitmq/docker-compose.yml \
  images/rabbitmq/docker-compose-cluster.yml \
  images/rabbitmq/rabbitmq-build-and-push.sh
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add GitHub Actions workflow to build and push rabbitmq to GHCR

Same template already validated for redis, redis-sentinel, and os-shell:
multi-arch (amd64+arm64) build, a RabbitMQ-specific smoke test
(rabbitmq-diagnostics ping, the image's own healthcheck command), and
push to GHCR on merge to main. Removes the now-obsolete
rabbitmq-build-and-push.sh, fully replaced by CI. This is the last of the
four images in this repo to move off the AWS ECR flow.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
git show --stat HEAD
```
Expected: exactly the 7 staged paths.

---

### Task 6: Push, open a PR, and watch the real workflow run

Executed autonomously (per explicit user "auto mode" instruction) — no
confirmation checkpoint before pushing/opening the PR. Merging is still
left to the user.

- [ ] **Step 1: Check origin/main sync, push a branch**

```bash
git fetch origin main --quiet
git rev-list --left-right --count origin/main...main
```
If not `0	0`, fast-forward-push `main` first.

```bash
git push -u origin worktree-rabbitmq-ghcr-ci:rabbitmq-ghcr-ci
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --head rabbitmq-ghcr-ci --title "Add GHCR build/push workflow for rabbitmq" --body "$(cat <<'EOF'
## Summary
- Add .github/workflows/rabbitmq.yml: multi-arch (amd64+arm64) build +
  RabbitMQ-specific smoke test (rabbitmq-diagnostics ping) on every PR
  touching images/rabbitmq/**, build+push to
  ghcr.io/mindw/odd_images/rabbitmq on merge to main.
- Rewrite images/rabbitmq/README.md and the 2 docker-compose files to
  reference GHCR instead of the private ECR.
- Remove the now-obsolete images/rabbitmq/rabbitmq-build-and-push.sh.
- Last of the four images in this repo to move off the ECR flow.

## Test plan
- [ ] This PR's own `rabbitmq` workflow run builds successfully for both
      linux/amd64 and linux/arm64, and the smoke test passes (build-only,
      no push, since this is a PR).
- [ ] After merge, confirm the push-triggered run succeeds and all 4 tags
      appear on the GHCR package page.
EOF
)"
```

- [ ] **Step 3: Watch the real run and report the actual outcome**

```bash
gh run list --branch rabbitmq-ghcr-ci --limit 1
gh run watch --exit-status
```

- [ ] **Step 4: Leave the merge to the user**

Do not merge the PR.
