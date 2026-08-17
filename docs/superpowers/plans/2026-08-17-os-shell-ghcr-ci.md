# OS Shell GHCR CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds `os-shell` for `linux/amd64` and `linux/arm64`, smoke-tests it, and pushes it to GHCR whenever its source changes — the same template already validated for `redis` and `redis-sentinel`.

**Architecture:** One workflow file (`.github/workflows/os-shell.yml`), same shape as the other two, except the smoke test is a single one-shot `docker run --rm ... yq --version` instead of a background-daemon-plus-poll loop, since `os-shell` is a utility image, not a server.

**Tech Stack:** Same as the other two plans — GitHub Actions, `docker/setup-qemu-action@v3`, `docker/setup-buildx-action@v3`, `docker/login-action@v3`, `docker/build-push-action@v6`. Verification: `yq`, `grep`, a real PR run, a real push-triggered run.

Full design/rationale: `docs/superpowers/specs/2026-08-17-os-shell-ghcr-ci-design.md`.

## Global Constraints

- **Image path:** `ghcr.io/${{ github.repository }}/os-shell` (built from context, never hardcoded in the workflow).
- **Tag scheme, exactly 4, pushed together on `push` to `main`:** `${IMAGE}:${OS_SHELL_VERSION}`, `${IMAGE}:v${OS_SHELL_APP_VERSION}`, `${IMAGE}:v${MAJOR_MINOR}`, `${IMAGE}:latest`. (`vMAJOR_MINOR` and `vAPP_VERSION` will be identical strings since `OS_SHELL_APP_VERSION="12"` has no dot — expected, harmless, not a bug.)
- **`version.sh` must be `source`d, never executed.**
- **In scope:** `images/os-shell/**` and `.github/workflows/os-shell.yml` only. Do not touch `redis`, `redis-sentinel`, or `rabbitmq`.
- **No unit test framework exists in this repo.** Verification is `yq` YAML assertions, `grep` reference checks, and a real GitHub Actions run.
- **No per-task commits.** Only Task 3 commits, once. Never `git add -A` or `git add .` — stage only the exact file list given in Task 3.
- **No docker-compose files and no old build/push script exist for `os-shell`** — both were already removed/never existed; nothing to delete in this plan.
- **Do not add a GHCR-package-visibility caveat to the README** — carried-over decision from the other two images.
- **Task 4 (push branch, open PR, watch the real run)** is executed autonomously per explicit user instruction ("auto mode") — no confirmation checkpoint needed before pushing/opening the PR. **Merging the resulting PR is still left to the user, never the agent** — this boundary is unchanged.

---

### Task 1: Add the `os-shell` GitHub Actions workflow

**Files:**
- Create: `.github/workflows/os-shell.yml`

- [ ] **Step 1: Confirm the file doesn't exist yet**

Run: `yq '.on.pull_request.paths' .github/workflows/os-shell.yml`
Expected: FAIL — `Error: no such file or directory`

- [ ] **Step 2: Write the workflow file**

Create `.github/workflows/os-shell.yml` with exactly this content:

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

- [ ] **Step 3: Validate the YAML parses and the key fields are correct**

```bash
yq eval '.' .github/workflows/os-shell.yml > /dev/null && echo VALID
yq '.on.pull_request.paths' .github/workflows/os-shell.yml
yq '.concurrency.group' .github/workflows/os-shell.yml
yq '.permissions.packages' .github/workflows/os-shell.yml
yq '.jobs.build.steps[] | select(.name == "Smoke test") | .run' .github/workflows/os-shell.yml
yq '.jobs.build.steps[-1].with.provenance' .github/workflows/os-shell.yml
```

Expected, in order:
```
VALID
- images/os-shell/**
- .github/workflows/os-shell.yml
os-shell-${{ github.ref }}
write
docker run --rm os-shell-smoke-test:local yq --version
false
```

---

### Task 2: Rewrite `images/os-shell/README.md`

**Files:**
- Modify: `images/os-shell/README.md`

- [ ] **Step 1: Confirm the check currently fails**

```bash
grep -c "ghcr.io/mindw/odd_images" images/os-shell/README.md; grep -c "569129334545" images/os-shell/README.md; grep -c "skopeo" images/os-shell/README.md
```
Expected: `0`, `5`, `2`.

- [ ] **Step 2: Rewrite the "Engageli notes" section (lines 10-32, up to but not including `## TL;DR`)**

Old:
```markdown
## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/os-shell)
2. backup image source files:  `AWS_PROFILE=shared_assets ./copy-image-sources-s3.sh`
3. Build and push using `AWS_PROFILE=shared_assets ./os-shell-12-build-and-push.sh`
4. Deploy on a dev cluster
5. Once merged, promote tag as `latest` and VERSION latest :
   ```
   . 12/debian-12/version.sh
   # add "latest"
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/os-shell ${OS_SHELL_VERSION}
   # add VERSION latest
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/os-shell ${OS_SHELL_VERSION} v${OS_SHELL_APP_VERSION} 
   ```
6. Once merged, propagate image to `test` and `prod` repos using `aws/misc/ecr.py`: 
   ``` 
   . 12/debian-12/version.sh 
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${OS_SHELL_VERSION} --ci -s dev -d test -r bitnami/os-shell
   # and to production once the PR is merged
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${OS_SHELL_VERSION} --ci -r bitnami/os-shell
   ```
```

New:
```markdown
## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/os-shell)
2. Bump `current/debian-12/Dockerfile` to the new version
3. Open a pull request — the `os-shell` GitHub Actions workflow builds the image for `linux/amd64` and `linux/arm64` and runs a smoke test to confirm it still works. No image is pushed for pull requests.
4. Once the PR is merged to `main`, the same workflow builds, smoke-tests, and pushes the image to GHCR, tagged as `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, and `latest` in one step.
```

- [ ] **Step 3: Replace the TL;DR line**

Old:
```markdown
docker run -ti --rm --name os-shell 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell-dev:latest
```
New:
```markdown
docker run -ti --rm --name os-shell ghcr.io/mindw/odd_images/os-shell:latest
```

- [ ] **Step 4: Rewrite the "Get this image" pull/skopeo block**

Old:
```markdown
The recommended way to get the Bitnami os-shell Docker Image is to pull the prebuilt image
from the Engageli private ECR repository.

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell-dev:latest
```

To use a specific version, you can pull a versioned tag. You can view the list of 
available versions using `skopeo`:
```
skopeo list-tags docker://569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell-dev | jq .Tags[] -r
```

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell:[TAG]
```
```

New:
```markdown
The recommended way to get the os-shell Docker image is to pull the prebuilt image
from the Engageli GitHub Container Registry.

```console
docker pull ghcr.io/mindw/odd_images/os-shell:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of
available versions on the [package page](https://github.com/mindw/odd_images/pkgs/container/odd_images%2Fos-shell).

```console
docker pull ghcr.io/mindw/odd_images/os-shell:[TAG]
```
```

(Leave the following "If you wish, you can also build the image yourself..."
block, lines 59-65 in the original file, untouched — it's about the
upstream `bitnami/containers` repo, not our registry.)

- [ ] **Step 5: Replace the "Running commands" example**

Old:
```markdown
docker run --rm --name os-shell 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell:latest echo hello world
```
New:
```markdown
docker run --rm --name os-shell ghcr.io/mindw/odd_images/os-shell:latest echo hello world
```

- [ ] **Step 6: Re-run the check and confirm it now passes**

```bash
grep -c "ghcr.io/mindw/odd_images" images/os-shell/README.md; grep -c "569129334545" images/os-shell/README.md; grep -c "skopeo" images/os-shell/README.md
```
Expected: `4`, `0`, `0`.

---

### Task 3: Review and single commit (spec + plan + implementation)

- [ ] **Step 1: Show the diff for review**

```bash
git status --porcelain -- docs/ .github/ images/os-shell/README.md
git diff -- images/os-shell/README.md
```

Confirm this is exactly the expected file list: 2 new docs, the new
workflow, the README change — nothing from `redis`, `redis-sentinel`, or
`rabbitmq`.

- [ ] **Step 2: Stage exactly these paths (never `-A` or `.`)**

```bash
git add \
  docs/superpowers/specs/2026-08-17-os-shell-ghcr-ci-design.md \
  docs/superpowers/plans/2026-08-17-os-shell-ghcr-ci.md \
  .github/workflows/os-shell.yml \
  images/os-shell/README.md
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add GitHub Actions workflow to build and push os-shell to GHCR

Same template already validated for redis and redis-sentinel: multi-arch
(amd64+arm64) build, a one-shot smoke test (os-shell has no daemon to
poll, unlike the other two images), and push to GHCR on merge to main;
build-only validation on every PR touching images/os-shell/**.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
git show --stat HEAD
```
Expected: exactly the 4 staged paths.

---

### Task 4: Push, open a PR, and watch the real workflow run

Executed autonomously (per explicit user instruction) — no confirmation
checkpoint before pushing/opening the PR. Merging the PR is still left to
the user.

- [ ] **Step 1: Check origin/main sync, push a branch**

```bash
git fetch origin main --quiet
git rev-list --left-right --count origin/main...main
```
If not `0	0`, fast-forward-push `main` first (same issue hit twice
before), so the PR diff doesn't bundle in unrelated prior commits.

```bash
git push -u origin worktree-os-shell-ghcr-ci:os-shell-ghcr-ci
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --head os-shell-ghcr-ci --title "Add GHCR build/push workflow for os-shell" --body "$(cat <<'EOF'
## Summary
- Add .github/workflows/os-shell.yml: multi-arch (amd64+arm64) build +
  one-shot smoke test (`yq --version`) on every PR touching
  images/os-shell/**, build+push to ghcr.io/mindw/odd_images/os-shell on
  merge to main.
- Rewrite images/os-shell/README.md to reference GHCR instead of the
  private ECR (the old build/push and S3-backup scripts were already
  removed in a prior cleanup commit).
- Same template already validated and merged for redis and
  redis-sentinel, including the concurrency guard and provenance:false
  fix.

## Test plan
- [ ] This PR's own `os-shell` workflow run builds successfully for both
      linux/amd64 and linux/arm64, and the smoke test passes (build-only,
      no push, since this is a PR).
- [ ] After merge, confirm the push-triggered run succeeds and all 4 tags
      appear on the GHCR package page.
EOF
)"
```

- [ ] **Step 3: Watch the real run and report the actual outcome**

```bash
gh run list --branch os-shell-ghcr-ci --limit 1
gh run watch --exit-status
```

Report the actual result — do not report success until `gh run watch` has
shown it.

- [ ] **Step 4: Leave the merge to the user**

Do not merge the PR.
