# Security Audit Status

The weekly `security-audit.yml` workflow (Trivy + Grype, `--fail-on high --only-fixed`)
scans the published image every Tuesday. This file tracks known, investigated
exceptions so the CI state doesn't need to be re-diagnosed from scratch each time it
comes up.

| CVE | Package | Status | Why | Resolves when |
|---|---|---|---|---|
| ~20 historical curl CVEs (CVE-2024-2398, CVE-2026-11856, CVE-2026-10536, CVE-2026-8927, etc.) | curl 8.5.8 | Suppressed (`.grype.yaml`) | Grype misreads PHP's own embedded version string (`8.5.8`) inside the `curl.so` PHP extension file (`/usr/local/lib/php/extensions/.../curl.so`) and misattributes it as the curl library's version. The real runtime `libcurl.so.4.8.0` (`.8.0` is an ABI/soname suffix, not the curl version) embeds `libcurl/8.21.0` -- already patched, confirmed via `strings` on the published image. | N/A -- no real vulnerable curl version is shipped. Rule is locked to `curl 8.5.8` and becomes inert automatically if the underlying alpine `libcurl` package or PHP's own version string ever changes such that a genuine match reappears. |

Previously resolved (kept for context):

| Issue | Fixed by |
|---|---|
| GO-2026-4970, GO-2026-5856 (Go stdlib) | Bumped `golang:1.26-alpine` digest (2026-07-15) |
| Stale `libcurl` in the published image | Alphabetized the `prep` stage's `apk add` package list to bust the GitHub Actions layer cache, forcing a fresh `apk` resolution against alpine 3.24's current repo index (2026-07-15) |

## Old vulnerable image tags left publicly pullable (found 2026-07-21, fixed)

Same root cause as `nginx-hardened`: `build-push.yml` pushes a new immutable version
tag (e.g. `8.4.22`) on every run, in addition to `:latest`, on both Docker Hub and
GHCR, and never retired the previous one. Confirmed via a direct `grype` scan against
the old published tags (`8.4.21`, `8.5.3`, `8.4.22`) -- all three failed with real,
currently-unfixed findings beyond the already-documented `curl 8.5.8` false positive
above: apk-level CVEs in `openssl`/`libcrypto3`/`libssl3`, `libexpat`, `imagemagick-libs`,
`c-ares` (on `8.4.21`), plus `php-cli`/`php-fpm` CVE-2026-14355 and the Go stdlib
`GO-2026-4970`/`5856` findings (on `8.5.3`/`8.4.22`).

Fixed by `registry-cleanup.yml` (`scripts/prune-registry-tags.sh` for Docker Hub,
`scripts/prune-ghcr-tags.sh` for GHCR), called as a job from `build-push.yml` after
every push, and directly `workflow_dispatch`-able. Keeps the last 3 semver tags +
`:latest`. Only ever deletes a package version by its own named tag -- untagged
manifest-list children, attestations, and cosign signatures are left alone.

**Important caveat** (hit on `nginx-hardened`'s first run, applies here too): "keep the
last 3 semver tags" is generic hygiene, not CVE-aware. After any prune run,
cross-check the surviving semver tags with a direct `grype <image>:<tag> --fail-on
high --only-fixed --config .grype.yaml` scan -- if one inside the keep-window is
still flagged, delete it explicitly.
