# Bitnami Upstream Sync (November 2026) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring all five images to the latest upstream Bitnami release (RabbitMQ held on 4.3) by copying upstream's Dockerfiles and checksum files, ending with one open PR whose five workflow runs are green.

**Architecture:** No code is written. Each image's `Dockerfile` and `prebuildfs/opt/bitnami/checksums/` are replaced with the files from a pinned `bitnami/containers` commit; a `diff -rq` against that same tree proves the result. Two READMEs get small fixes. Local amd64 builds run the exact smoke-test script each workflow uses, then CI covers arm64 on the PR.

**Tech Stack:** git (sparse clone), `diff`, Docker buildx, `yq`, `gh`, GitHub Actions (existing workflows, unchanged).

**Spec:** `docs/superpowers/specs/2026-11-15-bitnami-upstream-sync-design.md`

## Global Constraints

- **Upstream pin:** `bitnami/containers` commit `ce83c8a3c7bef4cbf9796f1a38a4e6adb8f49b8b`. Never copy from `main` or any other commit.
- **Image → upstream directory:** `os-shell` → `bitnami/os-shell/12/debian-12`; `rabbitmq` → `bitnami/rabbitmq/4.3/debian-12`; `redis` → `bitnami/redis/8.10/debian-12`; `redis-cluster` → `bitnami/redis-cluster/8.10/debian-12`; `redis-sentinel` → `bitnami/redis-sentinel/8.10/debian-12`.
- **Target versions:** redis, redis-cluster, redis-sentinel `8.10.3-r1`; rabbitmq `4.3.7-r4`; os-shell `12-r84`.
- **RabbitMQ stays on the 4.3 line.**
- **No hand-typed version string or checksum.** Dockerfiles and checksum files are copied whole, never edited.
- **Files that may change:** the five `images/<image>/current/debian-12/Dockerfile`, the files under the five `.../prebuildfs/opt/bitnami/checksums/` directories, `images/redis/README.md`, `images/rabbitmq/README.md`, and the two docs under `docs/superpowers/`. Nothing else: no workflows, `version.sh`, compose files, scripts, or `extract-version-bitnami-images.sh`.
- **`version.sh` must be `source`d, never executed.**
- **Branch:** `sync-upstream-2026-11`, off `main`. Never commit to `main`.
- **Staging:** never `git add -A` or `git add .`; stage the paths each task names.
- **No images are pushed by hand.** Merging the PR is left to the repo owner, never the agent.
- **`$UPSTREAM`** in the commands below is a directory outside the repo holding the pinned upstream tree (created in Task 1). Shell variables do not persist between commands; set it again at the top of each command block.

## Review Focus

1. **arm64 is never built locally.** Expect the PR's "Build and push" step (amd64 + arm64, `push: false`) to succeed for all five workflows. Pinned in Task 4, Step 3.
2. **Upstream moved since the pin.** Expect the copied tree to be commit `ce83c8a…` exactly. Pinned in Task 1, Step 2.
3. **An old checksum file left behind.** The build would still pass, but the directory would no longer match upstream. Pinned by the `diff -rq` in Task 1, Step 5.
4. **A file outside the allowed list changed.** Pinned by the stray-file check in Task 1, Step 6 and again in Task 4, Step 1.
5. **Moving tags resolve wrongly.** The workflows derive `vMAJOR.MINOR` from the Dockerfile; expect `v8.10` and `v4.3`. Pinned in Task 1, Step 5.

---

### Task 1: Sync Dockerfiles and checksums from pinned upstream

**Files:**
- Modify: `images/{os-shell,rabbitmq,redis,redis-cluster,redis-sentinel}/current/debian-12/Dockerfile`
- Replace contents: `images/{os-shell,rabbitmq,redis,redis-cluster,redis-sentinel}/current/debian-12/prebuildfs/opt/bitnami/checksums/`
- Add (already written, untracked): `docs/superpowers/specs/2026-11-15-bitnami-upstream-sync-design.md`, `docs/superpowers/plans/2026-11-15-bitnami-upstream-sync.md`

**Interfaces:**
- Produces: branch `sync-upstream-2026-11`; `$UPSTREAM` tree at the pinned commit, reused by Task 2.

- [ ] **Step 1: Create the branch and commit the docs**

```bash
git switch -c sync-upstream-2026-11
git add docs/superpowers/specs/2026-11-15-bitnami-upstream-sync-design.md docs/superpowers/plans/2026-11-15-bitnami-upstream-sync.md
git commit -m "Add design and plan for November 2026 upstream sync"
```

- [ ] **Step 2: Fetch the pinned upstream tree**

```bash
UPSTREAM=<scratch dir outside the repo>/bitnami-containers
git init -q "$UPSTREAM"
git -C "$UPSTREAM" remote add origin https://github.com/bitnami/containers.git
git -C "$UPSTREAM" sparse-checkout set --no-cone bitnami/os-shell bitnami/rabbitmq bitnami/redis bitnami/redis-cluster bitnami/redis-sentinel
git -C "$UPSTREAM" fetch -q --depth 1 --filter=blob:none origin ce83c8a3c7bef4cbf9796f1a38a4e6adb8f49b8b
git -C "$UPSTREAM" checkout -q FETCH_HEAD
git -C "$UPSTREAM" rev-parse HEAD
```

Expected: `ce83c8a3c7bef4cbf9796f1a38a4e6adb8f49b8b`

- [ ] **Step 3: Run the check and watch it fail**

Save this as the check; it is run again in Step 5.

```bash
UPSTREAM=<same dir>
for pair in os-shell:12 rabbitmq:4.3 redis:8.10 redis-cluster:8.10 redis-sentinel:8.10; do
  n=${pair%%:*}; l=${pair##*:}
  echo "== $n"
  diff -rq "images/$n/current/debian-12" "$UPSTREAM/bitnami/$n/$l/debian-12"
  ( source "images/$n/current/debian-12/version.sh"; env | grep -E '_VERSION=v' )
done
( source images/redis/current/debian-12/version.sh;    echo "redis line: ${REDIS_APP_VERSION%.*}" )
( source images/rabbitmq/current/debian-12/version.sh; echo "rabbitmq line: ${RABBITMQ_APP_VERSION%.*}" )
ls images/*/current/debian-12/prebuildfs/opt/bitnami/checksums | grep -c 'sha256$'
```

Expected now: FAIL. Every image reports `Dockerfile ... differ` and several `Only in ... checksums` lines, and the versions are the old ones (`v8.10.1-debian-12-r0`, `v4.3.5-debian-12-r0`, `v12-debian-12-r72`).

- [ ] **Step 4: Copy the Dockerfile and checksums for each image**

For each of the five images, with `$n` the image and `$l` its line from Global Constraints: copy `$UPSTREAM/bitnami/$n/$l/debian-12/Dockerfile` over `images/$n/current/debian-12/Dockerfile`; delete every file in `images/$n/current/debian-12/prebuildfs/opt/bitnami/checksums/`; copy every file from the upstream `checksums/` directory into it. Copy nothing else (in particular, not upstream's `docker-compose.yml`).

- [ ] **Step 5: Run the check and watch it pass**

Run the Step 3 block again. Expected, and nothing more:

```
== os-shell
Only in images/os-shell/current/debian-12: version.sh
OS_SHELL_VERSION=v12-debian-12-r84
== rabbitmq
Only in <UPSTREAM>/bitnami/rabbitmq/4.3/debian-12: docker-compose.yml
Only in images/rabbitmq/current/debian-12: version.sh
RABBITMQ_VERSION=v4.3.7-debian-12-r4
== redis
Files images/redis/current/debian-12/docker-compose.yml and <UPSTREAM>/bitnami/redis/8.10/debian-12/docker-compose.yml differ
Only in images/redis/current/debian-12: version.sh
REDIS_VERSION=v8.10.3-debian-12-r1
== redis-cluster
Files images/redis-cluster/current/debian-12/docker-compose.yml and <UPSTREAM>/bitnami/redis-cluster/8.10/debian-12/docker-compose.yml differ
Only in images/redis-cluster/current/debian-12: version.sh
REDIS_CLUSTER_VERSION=v8.10.3-debian-12-r1
== redis-sentinel
Only in images/redis-sentinel/current/debian-12: version.sh
REDIS_SENTINEL_VERSION=v8.10.3-debian-12-r1
redis line: 8.10
rabbitmq line: 4.3
22
```

- [ ] **Step 6: Confirm no stray file changed**

```bash
git status --short | grep -vE 'Dockerfile$|/checksums/' 
```

Expected: no output other than the untracked `?? .claude/` line.

- [ ] **Step 7: Commit**

```bash
git add images/*/current/debian-12/Dockerfile
git add -A images/*/current/debian-12/prebuildfs/opt/bitnami/checksums
git commit -m "Sync all images with upstream Bitnami (redis 8.10.3, rabbitmq 4.3.7, os-shell r84)"
```

(`git add -A <path>` is scoped to the checksum directories so the deletions are staged; it is not the repo-wide `git add -A` the constraints forbid.)

---

### Task 2: README fixes

**Files:**
- Modify: `images/redis/README.md` (update steps near line 8; env-var table near line 102)
- Modify: `images/rabbitmq/README.md` (update steps near line 8)

**Interfaces:**
- Consumes: `$UPSTREAM` tree from Task 1 (source of the table row).

- [ ] **Step 1: Run the checks and watch them fail**

```bash
grep -c 'copy-image-sources-s3' images/redis/README.md images/rabbitmq/README.md
grep -c 'REDIS_SENTINEL_PASSWORD' images/redis/README.md
```

Expected now: `images/redis/README.md:1`, `images/rabbitmq/README.md:1`, then `0`.

- [ ] **Step 2: Add the missing row to the redis README**

Directly after the `REDIS_SENTINEL_PORT_NUMBER` row in the customizable environment variables table, insert the `REDIS_SENTINEL_PASSWORD` row copied verbatim from `$UPSTREAM/bitnami/redis/README.md` (`grep REDIS_SENTINEL_PASSWORD` finds its one line).

- [ ] **Step 3: Remove the stale backup step from both READMEs**

In the "Updating to a new version" list of each README, delete step 2 (`Backup image source files using: AWS_PROFILE=shared_assets ./copy-image-sources-s3.sh`) and renumber the remaining steps 1–4. Change no other wording.

- [ ] **Step 4: Run the checks and watch them pass**

Run the Step 1 commands again. Expected: `images/redis/README.md:0`, `images/rabbitmq/README.md:0`, then `1`. Then:

```bash
UPSTREAM=<same dir>
diff <(grep -E '^\| `' images/redis/README.md | sort) <(grep -E '^\| `' "$UPSTREAM/bitnami/redis/README.md" | sort)
git diff --stat -- images/redis/README.md images/rabbitmq/README.md
```

Expected: the `diff` prints nothing; the stat shows redis with 4 insertions and 4 deletions (3 renumbered steps, 1 deleted step, 1 added row) and rabbitmq with 3 insertions and 4 deletions (3 renumbered steps, 1 deleted step).

- [ ] **Step 5: Commit**

```bash
git add images/redis/README.md images/rabbitmq/README.md
git commit -m "READMEs: add REDIS_SENTINEL_PASSWORD row, drop removed S3 backup step"
```

---

### Task 3: Local amd64 build and smoke test

**Files:** none changed.

**Interfaces:**
- Consumes: the synced Dockerfiles from Task 1; each workflow's existing "Smoke test" step.

- [ ] **Step 1: Build each image for amd64**

For each image `$n`, using the tag its workflow's smoke step expects:

```bash
docker build --platform linux/amd64 -t "$n-smoke-test:local" "images/$n/current/debian-12"
```

Expected: all five builds succeed, including every `sha256sum -c` line reporting `OK`. A checksum or download failure here means the copy in Task 1 is wrong or a tarball is gone; stop and report, do not edit a checksum.

- [ ] **Step 2: Run each workflow's own smoke-test script**

```bash
for n in os-shell rabbitmq redis redis-cluster redis-sentinel; do
  echo "== $n"
  yq '.jobs.build.steps[] | select(.name == "Smoke test") | .run' ".github/workflows/$n.yml" | bash -e || echo "FAILED: $n"
done
```

Expected: `yq` version output for os-shell, `RabbitMQ responded to ping`, `Redis responded to ping`, `Redis Cluster responded to ping`, `Redis Sentinel responded to ping`, and no `FAILED` line.

- [ ] **Step 3: Confirm the binaries are the new versions**

```bash
docker run --rm os-shell-smoke-test:local yq --version
for n in redis redis-cluster redis-sentinel; do docker run --rm --entrypoint redis-cli "$n-smoke-test:local" --version; done
docker run --rm --entrypoint rabbitmqctl rabbitmq-smoke-test:local version
```

Expected: `yq` reports `4.54.2`; each `redis-cli` reports `8.10.3`; `rabbitmqctl` reports `4.3.7`. If `rabbitmqctl version` refuses to run without a node, start the container as the smoke test does and run `rabbitmq-diagnostics -q server_version` in it instead.

- [ ] **Step 4: Clean up**

Remove the five `*-smoke-test:local` images and confirm `docker ps -a --filter name=-smoke` lists no containers.

---

### Task 4: Push, open the PR, confirm CI

**Files:** none changed.

- [ ] **Step 1: Confirm the branch contains only allowed files**

```bash
git status --short
git diff --name-only main...HEAD | grep -vE '^images/[a-z-]+/current/debian-12/(Dockerfile|prebuildfs/opt/bitnami/checksums/[^/]+\.sha256)$|^images/(redis|rabbitmq)/README\.md$|^docs/superpowers/(specs|plans)/2026-11-15-'
```

Expected: `git status` shows only `?? .claude/`; the second command prints nothing.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin sync-upstream-2026-11
gh pr create --base main --title "Sync all images with upstream Bitnami (November 2026)" --body-file <file>
```

The body states the before/after version table from the spec, that the Dockerfiles and checksums are copied unmodified from `bitnami/containers@ce83c8a3c7bef4cbf9796f1a38a4e6adb8f49b8b`, the two README fixes, and that merging republishes `:latest`, `:v8.10` and `:v4.3`. There is no PR template in this repo.

- [ ] **Step 3: Watch the five workflow runs**

```bash
gh pr checks --watch
```

Expected: five checks (`os-shell`, `rabbitmq`, `redis`, `redis-cluster`, `redis-sentinel`), all passing. For each, confirm the "Build and push" step ran and succeeded (this is the only arm64 build) and that "Log in to GHCR" was skipped. If a run fails, read its log with `gh run view <id> --log-failed` and report; do not retry blindly.

- [ ] **Step 4: Hand over**

Report the PR URL and the five run results. Do not merge.
