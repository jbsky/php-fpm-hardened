# PHP-FPM Hardened (WordPress-optimized)

Image Docker PHP-FPM 8.4 Alpine multi-stage hardenee pour WordPress.

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

- Multi-stage build (builder + production)
- Alpine minimal (pas de compilateurs dans l'image finale)
- Execution non-root (uid 1999, user `phpfpm`)
- `disable_functions` : exec, passthru, shell_exec, system, proc_open, popen
- `expose_php = Off`, `cgi.fix_pathinfo = 0`
- `open_basedir` restreint a `/var/www/html:/tmp`
- Sessions securisees (httponly, secure, samesite strict)
- OPcache + JIT tracing
- Healthcheck FPM integre (ping/pong via cgi-fcgi)
- Docker Compose : `read_only`, `no-new-privileges`, `cap_drop: ALL`
- `tmpfs` pour /tmp, /var/run, /var/log
- CI/CD : lint (hadolint + shellcheck), build, sign (cosign), scan (Trivy)

## Usage rapide

```bash
make build   # Build l'image
make up      # Demarre
make test    # Smoke tests (healthcheck + extensions + security)
make scan    # Trivy scan
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
Dockerfile              # Multi-stage build
docker-compose.yml      # Stack hardenee
Makefile                # Raccourcis dev
conf/
  php/
    php-hardened.ini    # Securite PHP
    opcache.ini         # OPcache + JIT
    wordpress.ini       # Uploads, realpath cache
  fpm/
    php-fpm.conf        # Config master FPM
    www.conf            # Pool www (workers, status)
    docker.conf         # Docker stderr override
scripts/
  entrypoint.sh         # Init runtime
  test.sh               # Smoke tests
  deploy.sh             # Build/scan/sbom helper
```

## CI/CD

| Stage | Job |
|-------|-----|
| lint | hadolint + shellcheck |
| build | buildx multi-arch + registry push |
| sign | cosign keyless OIDC |
| scan | Trivy SARIF |
| release | tarball sur tag |
