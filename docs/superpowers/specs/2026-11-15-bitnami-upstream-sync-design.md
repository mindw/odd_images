# Design: sync all images with upstream Bitnami (November 2026)

## Intent

Routine catch-up. Bring every image in this repo to the latest release
upstream publishes in `bitnami/containers`, with RabbitMQ held on the 4.3
line. No specific fix or advisory is driving it.

## Target versions

Upstream is pinned to `bitnami/containers` commit
`ce83c8a3c7bef4cbf9796f1a38a4e6adb8f49b8b` (main, 2026-11-14).

| Image | Upstream directory | Now | After |
|---|---|---|---|
| redis | `bitnami/redis/8.10/debian-12` | 8.10.1-r0 | 8.10.3-r1 |
| redis-cluster | `bitnami/redis-cluster/8.10/debian-12` | 8.10.1-r0 | 8.10.3-r1 |
| redis-sentinel | `bitnami/redis-sentinel/8.10/debian-12` | 8.10.1-r0 | 8.10.3-r1 |
| rabbitmq | `bitnami/rabbitmq/4.3/debian-12` | 4.3.5-r0 | 4.3.7-r4 |
| os-shell | `bitnami/os-shell/12/debian-12` | 12-r72 | 12-r84 |

Bundled components that move with it: `wait-for-port` 1.0.11-1 → 1.0.11-5,
`yq` 4.53.3-3 → 4.54.2-0, `scuttle` 1.1.16-1 → 1.1.18-0, `render-template`
1.0.10-2 → 1.0.10-6, `ini-file` 1.4.10-2 → 1.4.10-7. Erlang stays at
27.3.4-3.

## Goals

- Each image's `current/debian-12/Dockerfile` and
  `prebuildfs/opt/bitnami/checksums/*` match upstream exactly.
- All five images build for `linux/amd64` and `linux/arm64` and pass their
  smoke tests in CI on the pull request.

## Non-goals

- No change to workflows, tag scheme, `version.sh`, compose files, or
  `extract-version-bitnami-images.sh`.
- No reusable sync script. Worth its own follow-up if these catch-ups keep
  recurring.

## Anti-goals

- RabbitMQ leaving the 4.3 line. (Moot today: 4.3 is the newest line
  upstream publishes; `bitnami/rabbitmq/4.2` is only a README stub.)
- Any hand-typed version string or checksum.
- Pushing images by hand. Publishing happens only through the workflows on
  merge to `main`.

## Constraints

- Scripts under `prebuildfs/` and `rootfs/` already match upstream byte for
  byte, as does rabbitmq's `config/advanced.config`. They must still match
  afterwards.
- All new component tarballs were confirmed downloadable from
  `downloads.bitnami.com/files/stacksmith` for both architectures on
  2026-11-15.
- Merging to `main` republishes the moving tags `:latest`, `:v8.10`,
  `:v4.3` (and os-shell's equivalents). Merging is the owner's decision.

## Approaches

- **A. Copy from upstream, one PR (chosen).** Take upstream's `Dockerfile`
  and checksum files as-is per image, delete the old checksums, re-diff
  against upstream to prove the result. One branch, one PR; all five
  path-filtered workflows run on it. Chosen because nothing is typed by
  hand and it is one mechanical change.
- **B. Same copy, one PR per image.** Separate merge and rollback per
  image, at the cost of five PRs; the three redis images move together
  anyway.
- **C. Reusable sync script first.** Makes the next catch-up one command,
  but is more to review and maintain now and has to encode the RabbitMQ
  line pin. Deferred.

## The change

On a branch off `main` (`sync-upstream-2026-11`), for each image:

1. Replace `images/<image>/current/debian-12/Dockerfile` with upstream's.
2. Replace the contents of
   `images/<image>/current/debian-12/prebuildfs/opt/bitnami/checksums/`
   with upstream's (22 files out, 22 in across the five images).

README fixes (my call, not requested):

- `images/redis/README.md`: add the `REDIS_SENTINEL_PASSWORD` row that
  upstream's environment-variable table has.
- `images/redis/README.md` and `images/rabbitmq/README.md`: remove the
  "Backup image source files using `copy-image-sources-s3.sh`" step and
  renumber; that script no longer exists in the repo.

## Verification

- `diff -rq images/<image>/current/debian-12 <upstream>/<image>/<line>/debian-12`
  reports only the known local-only differences: `version.sh` (all),
  `docker-compose.yml` (redis, redis-cluster differ; rabbitmq has it only
  upstream).
- `source version.sh` for each image yields the "After" version above.
- Local check before the PR (my call): build each image for amd64 and run
  the same commands as that image's workflow "Smoke test" step.
- The PR's five workflow runs are green. Nothing is pushed on a PR.

## Left to the builder

- Commit granularity on the branch.
- How to obtain the pinned upstream tree (sparse clone at the commit above
  is enough).
