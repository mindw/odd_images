# Redis GHCR CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds the `redis` image for `linux/amd64` and `linux/arm64` and pushes it to GHCR whenever its source changes, replacing the manual AWS-ECR flow, and rewrite all `redis`-image references (README, docker-compose files, build scripts) to match.

**Architecture:** One workflow file (`.github/workflows/redis.yml`), single job, `docker/build-push-action` with QEMU emulation for arm64 (Approach A from the design doc). PRs touching `images/redis/**` build both platforms without pushing; pushes to `main` build, log into GHCR, and push 4 tags derived by sourcing `version.sh`.

**Tech Stack:** GitHub Actions, `docker/setup-qemu-action@v3`, `docker/setup-buildx-action@v3`, `docker/login-action@v3`, `docker/build-push-action@v6`. Verification tooling: `yq` (YAML), `docker compose config` (compose files), `grep` (reference-removal assertions), `gh` CLI (real PR run).

Full design/rationale: `docs/superpowers/specs/2026-08-16-redis-ghcr-ci-design.md`.

## Global Constraints

- **Image path:** `ghcr.io/mindw/odd_images/redis` (built from `github.repository`, i.e. `ghcr.io/${{ github.repository }}/redis` — do not hardcode `mindw/odd_images` in the workflow itself, only in verification-check expectations).
- **Tag scheme, exactly these 4, pushed together on `push` to `main`:** `${IMAGE}:${REDIS_VERSION}`, `${IMAGE}:v${REDIS_APP_VERSION}`, `${IMAGE}:v${MAJOR_MINOR}`, `${IMAGE}:latest`.
- **`version.sh` must be `source`d, never executed** — it only `export`s vars into the calling shell.
- **In scope:** `images/redis/**` and `.github/workflows/redis.yml` only. Do not touch `rabbitmq`, `os-shell`, `images/build-utils/` (pre-existing gap), or `images/redis/copy-image-sources-s3.sh` (unrelated to registry, keep as-is).
- **No unit test framework exists in this repo** (Bash/Docker/YAML infra, not app code). "Tests" in this plan are `yq` YAML assertions, `docker compose config` validation, and `grep` reference checks — run and shown to pass, not assumed.
- **No per-task commits.** The user explicitly asked to hold off on committing until the whole implementation is ready, and to commit the spec together with the implementation, not separately. Only Task 5 commits, once, and only after the user has approved this plan's execution reaching that point.
- **Never `git add -A` or `git add .`** for the Task 5 commit — `images/` and other directories in this repo contain unrelated untracked work-in-progress. Stage the exact file list given in Task 5, nothing else.
- **Pushing a branch, opening a PR, or merging a PR are visible, hard-to-reverse remote actions.** Per the user's standing operating rules, Task 6 (push + PR + watch the real run) requires an explicit go-ahead at execution time before the push/PR-creation steps — do not do this automatically just because the plan lists it as a step. Merging the resulting PR is explicitly left to the user, not the agent.

---

### Task 1: Add the `redis` GitHub Actions workflow

**Files:**
- Create: `.github/workflows/redis.yml`

**Interfaces:**
- Produces: the workflow file itself — Task 6 (push/PR) depends on this file existing and being syntactically valid.

- [ ] **Step 1: Confirm the file doesn't exist yet and the check fails**

Run: `yq '.on.pull_request.paths' .github/workflows/redis.yml`
Expected: FAIL — `Error: no such file or directory`

- [ ] **Step 2: Write the workflow file**

Create `.github/workflows/redis.yml` with exactly this content:

```yaml
name: redis

on:
  push:
    branches: [main]
    paths:
      - "images/redis/**"
      - ".github/workflows/redis.yml"
  pull_request:
    paths:
      - "images/redis/**"
      - ".github/workflows/redis.yml"

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

- [ ] **Step 3: Validate the YAML parses and the key fields are correct**

Run each and compare to the expected value:

```bash
yq eval '.' .github/workflows/redis.yml > /dev/null && echo VALID
yq '.on.pull_request.paths' .github/workflows/redis.yml
yq '.on.push.branches' .github/workflows/redis.yml
yq '.permissions.packages' .github/workflows/redis.yml
yq '.jobs.build.steps[-1].with.platforms' .github/workflows/redis.yml
yq '.jobs.build.steps[-1].with.push' .github/workflows/redis.yml
```

Expected, in order:
```
VALID
- images/redis/**
- .github/workflows/redis.yml
- main
write
linux/amd64,linux/arm64
${{ github.event_name == 'push' }}
```

If any line doesn't match, fix the file and re-run before moving on.

---

### Task 2: Rewrite `images/redis/README.md`

**Files:**
- Modify: `images/redis/README.md`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: nothing consumed by later tasks (README is documentation only).

- [ ] **Step 1: Confirm the check currently fails**

Run:
```bash
grep -c "ghcr.io/mindw/odd_images/redis" images/redis/README.md; grep -c "569129334545" images/redis/README.md; grep -c "skopeo" images/redis/README.md
```
Expected: `0` (or a "no matches" exit) for the first, `8` for the second, `2` for the third — the GHCR reference doesn't exist yet and the old ones do.

- [ ] **Step 2: Rewrite the "Engageli notes" section**

Replace lines 8–31 (the whole `## Engageli notes` section up to but not including `## TL;DR`):

Old:
```markdown
## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/redis)
2. backup image source files using: `AWS_PROFILE=shared_assets ./copy-image-sources-s3.sh`
3. Build and push using `AWS_PROFILE=shared_assets ./redis-build-and-push.sh`
4. Deploy on a dev cluster
5. Once merged, promote tag as `latest` and VERSION latest :
   ```
   . current/debian-12/version.sh
   # add "latest"
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/redis ${REDIS_VERSION}
   # add VERSION latest
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/redis ${REDIS_VERSION} v${REDIS_APP_VERSION}
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/redis ${REDIS_VERSION} v${REDIS_APP_VERSION%.*} 
   ```
6. Once merged, propagate image to `dev` and `prod` repos using `aws/misc/ecr.py`. 
   ``` 
   . current/debian-12/version.sh 
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${REDIS_VERSION} --ci -s dev -d test -r bitnami/redis
   # and to production once the PR is merged
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${REDIS_VERSION} --ci -r bitnami/redis
   ```
```

New:
```markdown
## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/redis)
2. Backup image source files using: `AWS_PROFILE=shared_assets ./copy-image-sources-s3.sh`
3. Bump `current/debian-12/Dockerfile` to the new version
4. Open a pull request — the `redis` GitHub Actions workflow builds the image for `linux/amd64` and `linux/arm64` to confirm it still builds. No image is pushed for pull requests.
5. Once the PR is merged to `main`, the same workflow builds and pushes the image to GHCR, tagged as `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, and `latest` in one step. No manual promotion or dev/prod propagation is needed.
```

- [ ] **Step 3: Rewrite the "Get this image" section**

Old:
```markdown
## Get this image

The recommended way to get the Bitnami Redis Docker image is to pull the prebuilt image
from the Engageli private ECR repository.

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/redis:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of 
available versions using `skopeo`:
```
skopeo list-tags docker://569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/redis | jq .Tags[] -r
```

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/redis:[TAG]
```
```

New:
```markdown
## Get this image

The recommended way to get the Redis Docker image is to pull the prebuilt image
from the Engageli GitHub Container Registry.

```console
docker pull ghcr.io/mindw/odd_images/redis:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of
available versions on the [package page](https://github.com/mindw/odd_images/pkgs/container/odd_images%2Fredis).

```console
docker pull ghcr.io/mindw/odd_images/redis:[TAG]
```
```

- [ ] **Step 4: Replace the remaining 4 ECR references**

These four lines each contain the literal substring
`569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/redis` inside an
otherwise-unrelated example command (lines ~154, ~196, ~251, ~276 in the
original file — the "Passing extra command-line flags", "Enabling Access
Control List", "Configuration file", and "Overriding configuration"
examples). Run:

```bash
sed -i 's#569129334545\.dkr\.ecr\.us-east-1\.amazonaws\.com/bitnami/redis#ghcr.io/mindw/odd_images/redis#g' images/redis/README.md
```

- [ ] **Step 5: Re-run the check and confirm it now passes**

Run:
```bash
grep -c "ghcr.io/mindw/odd_images/redis" images/redis/README.md; grep -c "569129334545" images/redis/README.md; grep -c "skopeo" images/redis/README.md
```
Expected: `6` for the first (2 from Step 3 + 4 from Step 4), `0` (no match) for the second and third.

---

### Task 3: Update the docker-compose files

**Files:**
- Modify: `images/redis/docker-compose.yml`
- Modify: `images/redis/docker-compose-replicaset.yml`
- Modify: `images/redis/current/debian-12/docker-compose.yml`

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Confirm the check currently fails**

Run:
```bash
grep -rc "ghcr.io/mindw/odd_images/redis" images/redis/docker-compose.yml images/redis/docker-compose-replicaset.yml images/redis/current/debian-12/docker-compose.yml
```
Expected: `0` for all three.

- [ ] **Step 2: Fix `images/redis/docker-compose.yml`**

Old (note the pre-existing double-slash typo — this also fixes it):
```yaml
    image: 569129334545.dkr.ecr.us-east-1.amazonaws.com//bitnami/redis:8.8
```
New:
```yaml
    image: ghcr.io/mindw/odd_images/redis:latest
```

- [ ] **Step 3: Fix `images/redis/current/debian-12/docker-compose.yml`**

Old:
```yaml
    image: 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/redis:8.8
```
New:
```yaml
    image: ghcr.io/mindw/odd_images/redis:latest
```

- [ ] **Step 4: Fix `images/redis/docker-compose-replicaset.yml` (2 occurrences)**

This file has the same line twice (once under `redis-primary`, once under
`redis-secondary`). Replace both:
```yaml
    image: 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/redis:8.8
```
with:
```yaml
    image: ghcr.io/mindw/odd_images/redis:latest
```

- [ ] **Step 5: Validate all three files still parse as valid compose files, and re-run the check**

```bash
docker compose -f images/redis/docker-compose.yml config -q && echo "docker-compose.yml OK"
docker compose -f images/redis/docker-compose-replicaset.yml config -q && echo "docker-compose-replicaset.yml OK"
docker compose -f images/redis/current/debian-12/docker-compose.yml config -q && echo "current/debian-12/docker-compose.yml OK"
grep -rc "ghcr.io/mindw/odd_images/redis" images/redis/docker-compose.yml images/redis/docker-compose-replicaset.yml images/redis/current/debian-12/docker-compose.yml
grep -rc "569129334545" images/redis/docker-compose.yml images/redis/docker-compose-replicaset.yml images/redis/current/debian-12/docker-compose.yml
```
Expected: all three `config -q` calls print their `OK` line with no error; the `ghcr.io` grep prints `1`, `2`, `1` (in file order); the ECR grep prints `0` for all three.

---

### Task 4: Remove the obsolete ECR build/push script

**Files:**
- Delete: `images/redis/redis-build-and-push.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Confirm it exists before deleting**

Run: `test -f images/redis/redis-build-and-push.sh && echo EXISTS`
Expected: `EXISTS`

- [ ] **Step 2: Delete it**

```bash
rm images/redis/redis-build-and-push.sh
```

- [ ] **Step 3: Confirm it's gone and its sibling script is untouched**

```bash
test -f images/redis/redis-build-and-push.sh && echo STILL_THERE || echo GONE
test -f images/redis/copy-image-sources-s3.sh && echo COPY_SCRIPT_STILL_PRESENT
```
Expected: `GONE`, then `COPY_SCRIPT_STILL_PRESENT`.

---

### Task 5: Review and single commit (spec + plan + implementation)

**Files:** none new — this stages and commits the outputs of Tasks 1–4 plus the design docs.

- [ ] **Step 1: Show the user the full diff for review**

```bash
git -C /home/mindw/work/odd_images status --porcelain -- docs/ .github/ images/redis/README.md images/redis/docker-compose.yml images/redis/docker-compose-replicaset.yml images/redis/current/debian-12/docker-compose.yml images/redis/redis-build-and-push.sh
git -C /home/mindw/work/odd_images diff -- images/redis/README.md images/redis/docker-compose.yml images/redis/docker-compose-replicaset.yml images/redis/current/debian-12/docker-compose.yml
```

Confirm with the user that this is exactly the file list expected: the two
new docs, the new workflow, the 4 modified/deleted `redis` files — nothing
from the rest of `images/` or from `.claude/`/`.idea/`.

- [ ] **Step 2: Stage exactly these paths (never `-A` or `.`)**

```bash
git add \
  docs/superpowers/specs/2026-08-16-redis-ghcr-ci-design.md \
  docs/superpowers/plans/2026-08-16-redis-ghcr-ci.md \
  .github/workflows/redis.yml \
  images/redis/README.md \
  images/redis/docker-compose.yml \
  images/redis/docker-compose-replicaset.yml \
  images/redis/current/debian-12/docker-compose.yml \
  images/redis/redis-build-and-push.sh
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add GitHub Actions workflow to build and push redis to GHCR

Replaces the manual AWS ECR build/push/promote flow for the redis image
with a multi-arch (amd64+arm64) GitHub Actions workflow that builds on
every PR touching images/redis/** and builds+pushes on merge to main.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify the commit**

```bash
git -C /home/mindw/work/odd_images show --stat HEAD
git -C /home/mindw/work/odd_images status --porcelain -- docs/ .github/ images/redis/
```
Expected: `show --stat` lists exactly the 8 staged paths; `status` shows nothing left staged/modified under those paths (the rest of `images/` remains untracked, untouched).

---

### Task 6: Push, open a PR, and watch the real workflow run (requires explicit go-ahead)

**This task pushes a branch and opens a real pull request against `github.com/mindw/odd_images` — a visible, remote, hard-to-fully-reverse action. Do not run these steps without the user explicitly confirming at execution time, even though this plan was approved.**

- [ ] **Step 1: Ask the user for explicit go-ahead to push and open the PR**

Do not proceed to Step 2 until the user says yes.

- [ ] **Step 2: Create a branch and push it**

```bash
git checkout -b redis-ghcr-ci
git push -u origin redis-ghcr-ci
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --title "Add GHCR build/push workflow for redis" --body "$(cat <<'EOF'
## Summary
- Add .github/workflows/redis.yml: multi-arch (amd64+arm64) build on every
  PR touching images/redis/**, build+push to ghcr.io/mindw/odd_images/redis
  on merge to main.
- Rewrite images/redis/README.md and docker-compose files to reference GHCR
  instead of the private ECR.
- Remove the now-obsolete images/redis/redis-build-and-push.sh.

## Test plan
- [ ] This PR's own `redis` workflow run builds successfully for both
      linux/amd64 and linux/arm64 (build-only, no push, since this is a PR).
- [ ] After merge, confirm the push-triggered run succeeds and all 4 tags
      appear on the GHCR package page.
EOF
)"
```

- [ ] **Step 4: Watch the real run and report the actual outcome**

```bash
gh run list --branch redis-ghcr-ci --limit 1
gh run watch --exit-status
```

Report the actual result (pass/fail, and the failure output if it fails) —
do not report this as working until `gh run watch` has actually shown a
successful conclusion for both platforms.

- [ ] **Step 5: Leave the merge to the user**

Do not merge the PR. Tell the user it's ready for review, and that merging
it is what triggers the real push-to-GHCR path (which they may want to
watch separately once merged).
