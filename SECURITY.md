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
