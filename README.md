# PHP-FPM Hardened (WordPress-optimized)

[![Build](https://github.com/jbsky/php-fpm-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/php-fpm-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/php-fpm-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/php-fpm-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/php-fpm-hardened#security--verification)

Image Docker PHP-FPM 8.5 hardenee (FROM scratch, Go init, tini PID 1), optimisee WordPress.

## Extensions incluses

| Extension | Usage |
|-----------|-------|
| opcache + JIT | Performances (cache bytecode + tracing JIT) |
| gd | Manipulation d'images (thumbnails, crops) |
| imagick | Traitement images avance (WebP, PDF previews) |
| mysqli | Base de donnees WordPress |
| zip / bz2 | Plugins, themes, backups |
| intl | Internationalisation |
| exif | Metadonnees photos |
| bcmath / gmp | Calculs precision (WooCommerce, crypto) |
| redis | Object cache (WP Redis plugin) |
| curl | HTTP client |
| sodium | Cryptographie (signatures WP) |

## Hardening

| Mesure | Detail |
|--------|--------|
| FROM scratch | Zero shell, zero package manager dans l'image finale |
| Go static init | Binary entrypoint + healthcheck (pas de script shell) |
| tini PID 1 | Signal forwarding + zombie reaping |
| Non-root | uid 1999, user `phpfpm` |
| Compiler hardening | RELRO, PIE, SSP, FORTIFY_SOURCE, stack-clash, NX |
| disable_functions | exec, passthru, shell_exec, system, proc_open, popen |
| open_basedir | Restreint a `/var/www/html:/tmp` |
| expose_php = Off | Pas de header X-Powered-By |
| Sessions securisees | httponly, secure, samesite strict |
| Docker Compose | `read_only`, `no-new-privileges`, `cap_drop: ALL` |
| tmpfs | /tmp, /var/run, /var/log (pas de write sur rootfs) |

## Usage rapide

```bash
cp .env.example .env
make build   # Build l'image
make up      # Demarre la stack
make test    # Smoke tests (healthcheck + extensions + security)
make scan    # Trivy vulnerability scan
make down    # Arrete
```

## Configuration runtime

Variables d'environnement (via `.env` ou docker-compose) :

| Variable | Default | Description |
|----------|---------|-------------|
| `WP_DEBUG` | `0` | Active le mode debug PHP (display_errors, opcache off) |
| `PHP_PM_MAX_CHILDREN` | `50` | Nombre max de workers FPM |
| `PHP_MEMORY_LIMIT` | `256M` | Limite memoire PHP |
| `PHP_UPLOAD_MAX_FILESIZE` | `64M` | Taille max upload |
| `TZ` | `UTC` | Timezone |

## Architecture

```
php-fpm-hardened/
├── Dockerfile              # Multi-stage build (Alpine → FROM scratch)
├── Dockerfile.wordpress    # Variante avec WP-CLI
├── docker-compose.yml      # Stack hardenee (read_only, cap_drop)
├── Makefile                # Raccourcis dev
├── versions.json           # Versions trackees (PHP, Alpine)
├── go.mod + init.go        # Go static init binary
├── conf/
│   ├── php/
│   │   ├── php-hardened.ini    # Securite PHP
│   │   ├── opcache.ini         # OPcache + JIT
│   │   └── wordpress.ini       # Uploads, realpath cache
│   └── fpm/
│       ├── php-fpm.conf        # Config master FPM
│       ├── www.conf            # Pool www (workers, status)
│       └── docker.conf         # Docker stderr override
├── scripts/
│   ├── entrypoint.sh       # Init runtime (legacy, unused in Platine)
│   ├── test.sh             # Smoke tests
│   └── deploy.sh           # Build/scan/sbom helper
└── .github/workflows/
    ├── build-push.yml      # Build + sign + scan + release
    ├── version-watch.yml   # Daily PHP patch detection
    └── security-audit.yml  # Weekly Trivy + Grype
```

## CI/CD

Dual pipeline (GitLab + GitHub Actions) :

| Stage | Description |
|-------|-------------|
| lint | hadolint + shellcheck |
| build | buildx multi-arch + push (ghcr.io + Docker Hub) |
| sign | cosign keyless OIDC |
| scan | Trivy SARIF + Grype |
| attest | SBOM + SLSA provenance (level 2) |
| version-watch | Cron quotidien — rebuild auto sur nouvelle version PHP |
| security-audit | Cron hebdomadaire — scan vulnerabilites sur images publiees |

## Security & Verification

This image is signed with [cosign](https://github.com/sigstore/cosign) using keyless OIDC (Sigstore).

### Verify image signature

```bash
# From ghcr.io (signatures stored natively)
cosign verify \
  --certificate-identity-regexp '^https://github.com/jbsky/php-fpm-hardened/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/jbsky/php-fpm-hardened:latest

# From Docker Hub (signatures stored in ghcr.io)
COSIGN_REPOSITORY=ghcr.io/jbsky/php-fpm-hardened \
  cosign verify \
  --certificate-identity-regexp '^https://github.com/jbsky/php-fpm-hardened/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/jbsky/php-fpm-hardened:latest
```

### Hardening tier "Platine" guarantees

| Property | Description |
|----------|-------------|
| FROM scratch | No base image, no shell, no package manager |
| Go static init | Binary entrypoint + healthcheck (no script) |
| tini PID 1 | Proper signal forwarding and zombie reaping |
| Non-root | Runs as unprivileged UID |
| Compiler hardening | RELRO, PIE, SSP, FORTIFY_SOURCE, stack-clash, NX |
| Cosign signed | OIDC keyless signature via Sigstore transparency log |
| SBOM | Software Bill of Materials embedded in manifest |
| SLSA provenance | Build provenance attestation (level 2) |

## License

MIT
