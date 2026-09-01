# =====================================================================
#  PHP-FPM Hardened — Multi-stage FROM scratch build
#  4-stage: builder -> gobuilder -> prep -> FROM scratch
#  Conformite Docker Hardened Image :
#   - FROM scratch final stage: zero shell, zero package manager
#   - utilisateur non-root (uid 1999)
#   - entrypoint + healthcheck en binaire Go statique (FastCGI PING/PONG)
#   - tini-static PID 1
#
#  Extensions: opcache, gd, imagick, intl, mysqli, zip, bz2, exif,
#              bcmath, gmp, sodium, redis, curl
#
#  Proxy-aware: passe http_proxy/https_proxy via les predefined ARGs
#  BuildKit (non baked dans l'image finale).
# =====================================================================

# ---------------------------------------------------------------------------
# Stage 0: builder — compile PHP extensions from source
# ---------------------------------------------------------------------------
FROM php:8.5.10-fpm-alpine@sha256:362a2ab83ed4eac1fcf62d8ca0c552f2e57d097a708d70a3f7afb647a2df75c1 AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Trust homelab CA if provided (for builds behind SSL-bumping proxy)
RUN --mount=type=secret,id=ca-certs,target=/tmp/ca-bundle.crt,required=false \
    if [ -f /tmp/ca-bundle.crt ]; then \
      cat /tmp/ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi

# Build deps for all extensions
RUN apk add --no-cache \
    autoconf automake build-base curl-dev freetype-dev g++ gcc \
    gmp-dev icu-dev imagemagick-dev libjpeg-turbo-dev libpng-dev \
    libwebp-dev libxml2-dev libzip-dev linux-headers lmdb-dev \
    make oniguruma-dev pcre2-dev zlib-dev bzip2-dev git

# Hardening flags for extensions compiled from source
ENV CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIC -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    CXXFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIC -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack"

# Configure + compile GD with full format support.
#
# intl est de retour (30/08/2026) : WordPress la liste dans les modules
# recommandes de Site Health (WP_Site_Health::get_test_php_extensions), et la
# consigne est de suivre ces recommandations. Cout mesure : ~10 Mo (4,6 Mo de
# bibliotheques ICU, 2,8 Mo de libstdc++ dont ICU est le seul consommateur,
# 2,9 Mo de donnees).
#
# Le piege qui l'avait fait retirer en aout reste entier : sur Alpine les
# donnees ICU ne sont pas dans libicudata.so (un stub de 12 Ko) mais dans
# /usr/share/icu/<v>/icudt<v>l.dat, un fichier de DONNEES qu'aucune cloture de
# dependances ne voit. Il est donc copie explicitement dans le stage prep.
#
# Donnees : icu-data-en (2,9 Mo), tire par icu-libs. icu-data-full coute
# 31,6 Mo et n'ajoute que les locales non anglaises d'ICU -- WordPress traduit
# ses dates avec ses propres catalogues (wp_date), pas avec ICU, et la
# collation d'un fr_FR reste correcte sans elles (mesure : abricot, eclair,
# eclair accentue, zebre). A rebasculer sur icu-data-full le jour ou du code
# appelle IntlDateFormatter en fr_FR : sans les donnees pleines, il rend
# "Sunday, August 30, 2026" au lieu de "dimanche 30 aout 2026".
RUN docker-php-ext-configure gd \
      --with-freetype \
      --with-jpeg \
      --with-webp && \
    docker-php-ext-install -j"$(nproc)" \
      bcmath \
      bz2 \
      curl \
      exif \
      gd \
      gmp \
      intl \
      mysqli \
      zip

# Opcache is compiled-in since PHP 8.5 — configured via ini only

# Imagick from git (PECL stable not yet available for PHP 8.5)
# hadolint ignore=DL3003
RUN git clone --depth 1 https://github.com/Imagick/imagick.git /tmp/imagick && \
    cd /tmp/imagick && phpize && ./configure && make -j"$(nproc)" && make install && \
    docker-php-ext-enable imagick && rm -rf /tmp/imagick

# Redis from git (PECL stable not yet available for PHP 8.5)
# hadolint ignore=DL3003
RUN git clone --depth 1 https://github.com/phpredis/phpredis.git /tmp/redis && \
    cd /tmp/redis && phpize && ./configure && make -j"$(nproc)" && make install && \
    docker-php-ext-enable redis && rm -rf /tmp/redis

# Strip extension .so files
RUN find /usr/local/lib/php/extensions -name '*.so' -exec strip --strip-unneeded {} +

# Record versions for downstream
RUN php -v | head -1 | awk '{print $2}' > /tmp/PHP_VER && \
    php -r 'echo phpversion("imagick");' > /tmp/IMAGICK_VER && \
    php -r 'echo phpversion("redis");' > /tmp/REDIS_VER && \
    echo "php=$(cat /tmp/PHP_VER) imagick=$(cat /tmp/IMAGICK_VER) redis=$(cat /tmp/REDIS_VER)" > /tmp/image-versions

# ---------------------------------------------------------------------------
# Stage 1: Go builder (entrypoint + healthcheck)
# ---------------------------------------------------------------------------
FROM golang:1.27-alpine@sha256:4c9fe60190a2a3350ddc51de80d0224b8a6698d12bdfc999fee45ea9d6c46dbc AS gobuilder
WORKDIR /build
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /init .

# ---------------------------------------------------------------------------
# Stage 2: prep (assemble runtime filesystem)
# ---------------------------------------------------------------------------
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS prep

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Runtime deps only (no compilers, no build tools)
# Split APK install to stay within proxy timeouts
# Package list kept alphabetized: any reordering also invalidates the
# GitHub Actions layer cache for this RUN, forcing a fresh `apk add`
# resolution against Alpine's current v3.24 repo index instead of silently
# reusing whatever package versions were cached the first time this exact
# instruction text was built (apk packages get security updates within a
# stable Alpine branch even though the base image digest doesn't change).
RUN apk add --no-cache \
    argon2-libs ca-certificates freetype gmp gnu-libiconv icu-libs \
    imagemagick-libs libbz2 libcurl libgcc libjpeg-turbo libpng \
    libsodium libwebp libxml2 libzip oniguruma pcre2 \
    readline sqlite-libs tini-static tzdata zlib

# Create non-root user
RUN addgroup -g 1999 -S phpfpm \
 && adduser -S -D -H -u 1999 -h /var/www/html -s /sbin/nologin -G phpfpm phpfpm

# Copy PHP binary from builder
# Le CLI /usr/local/bin/php n'est PAS embarque : 28,8 Mo pour un binaire que
# le service n'invoque jamais. php-fpm couvre -m, -v, -i et -d ; seul -r est
# propre au CLI, aucun usage de l'image n'en depend.
COPY --from=builder /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm

# Copy extensions + extension configs
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# Copy PHP base config structure (from php:8.5-fpm-alpine)
COPY --from=builder /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.conf
COPY --from=builder /usr/local/etc/php-fpm.d/ /usr/local/etc/php-fpm.d/
COPY --from=builder /usr/local/lib/libphp* /usr/local/lib/
COPY --from=builder /tmp/image-versions /etc/image-versions

# Copy our custom configuration (overrides defaults)
COPY --chown=root:phpfpm conf/php/php-hardened.ini /usr/local/etc/php/conf.d/zz-hardened.ini
COPY --chown=root:phpfpm conf/php/opcache.ini /usr/local/etc/php/conf.d/zz-opcache.ini
COPY --chown=root:phpfpm conf/php/wordpress.ini /usr/local/etc/php/conf.d/zz-wordpress.ini
COPY --chown=root:phpfpm conf/fpm/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY --chown=root:phpfpm conf/fpm/docker.conf /usr/local/etc/php-fpm.d/docker.conf
COPY --chown=root:phpfpm conf/fpm/php-fpm.conf /usr/local/etc/php-fpm.conf

# Harden: permissions, remove cruft
RUN rm -f /usr/local/etc/php-fpm.d/zz-docker.conf \
 && chmod 644 /usr/local/etc/php/conf.d/*.ini \
 && chmod 644 /usr/local/etc/php-fpm.d/*.conf \
 && chmod 644 /usr/local/etc/php-fpm.conf \
 && rm -f /usr/local/etc/php/php.ini-development /usr/local/etc/php/php.ini-production

# Strip APK/package-manager artifacts
# Collect exactly the shared objects that ship. Copying /lib and /usr/lib whole
# defeats the apk cleanup just below: it carried libapk.so along with it.
# lddtree lists each binary, its transitive dependencies, symlinks with their
# targets, and the loader for the architecture being built. It runs before apk
# is removed, since it needs apk to install itself.
#
# The PHP extensions are dlopen'd, so they are closure roots, enumerated with
# find rather than a glob: busybox sh hands an unmatched glob through
# literally. The build stops if that enumeration is empty.
#
# The "Not found" guard is not decoration: lddtree reports a missing library on
# stderr and still EXITS 0, so without it a dropped runtime package ships a
# closure with a hole in it and the failure only surfaces at container start.
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache lddtree \
 && mkdir -p /rootfs \
 && test -n "$(find /usr/local/lib/php/extensions -name '*.so' -print -quit)" \
 && { lddtree -l /usr/local/sbin/php-fpm; \
      find /usr/local/lib/php/extensions -name '*.so' -exec lddtree -l {} +; } \
      > /tmp/closure.list 2> /tmp/closure.err \
 && if grep -q 'Not found' /tmp/closure.list /tmp/closure.err; then \
      echo "closure incomplete -- a dependency is missing from this stage:" >&2; \
      grep 'Not found' /tmp/closure.list /tmp/closure.err >&2; \
      exit 1; \
    fi \
 && sort -u /tmp/closure.list -o /tmp/closure.list \
 && tar -cf /tmp/closure.tar -T /tmp/closure.list \
 && tar -xf /tmp/closure.tar -C /rootfs \
 && rm -f /tmp/closure.list /tmp/closure.err /tmp/closure.tar

# OpenSSL providers are dlopen'd, so no closure lists them. The 1.x engines
# (engines-3/) are deprecated and unused, as are the GObject introspection
# directories a dependency dragged in.
RUN mkdir -p /rootfs/usr/lib \
 && cp -a /usr/lib/ossl-modules /rootfs/usr/lib/

# Meme angle mort, pour une autre raison : les donnees ICU sont un fichier de
# DONNEES (/usr/share/icu/<v>/icudt<v>l.dat), pas une bibliotheque. Aucune
# cloture ne le liste, et son absence ne se voit pas a l'inspection --
# `php-fpm -i` affiche "ICU Data version" meme quand le fichier a ete supprime
# (verifie), c'est le premier Collator qui meurt en 255. D'ou la copie
# explicite et le test fonctionnel de scripts/test.sh.
RUN mkdir -p /rootfs/usr/share \
 && cp -a /usr/share/icu /rootfs/usr/share/ \
 && test -s "$(find /rootfs/usr/share/icu -name 'icudt*.dat' -print -quit)"

RUN rm -rf /lib/apk /lib/libapk* /var/cache/apk /etc/apk /sbin/apk

# ---------------------------------------------------------------------------
# Stage 3: FROM scratch (final hardened image)
# ---------------------------------------------------------------------------
FROM scratch

LABEL org.opencontainers.image.title="php-fpm-hardened" \
      org.opencontainers.image.description="PHP-FPM FROM scratch — WordPress-optimized, non-root, zero shell" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/jbsky/php-fpm-hardened" \
      security.hardening.tier="platine" \
      security.hardening.features="from-scratch,go-init,tini-pid1,zero-shell,non-root,compiler-hardening,cosign-signed,sbom,slsa-provenance"

# User accounts
COPY --link --from=prep /etc/passwd /etc/passwd
COPY --link --from=prep /etc/group  /etc/group

# Dynamic linker (musl) + shared libraries
COPY --link --from=prep /rootfs/ /

# PHP binary (php-fpm seul, voir la note du stage prep)
COPY --link --from=prep /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm

# PHP shared libraries (if any libphp*)
COPY --link --from=prep /usr/local/lib/ /usr/local/lib/

# PHP extensions + config
COPY --link --from=prep /usr/local/etc/ /usr/local/etc/

# Version info
COPY --link --from=prep /etc/image-versions /etc/image-versions

# TLS trust store + timezone data
COPY --link --from=prep /etc/ssl/ /etc/ssl/
COPY --link --from=prep /usr/share/zoneinfo/ /usr/share/zoneinfo/

# PID 1 — tini-static
COPY --link --from=prep /sbin/tini-static /sbin/tini

# Go init binary (static, entrypoint + healthcheck + setup-dirs)
COPY --link --from=gobuilder /init /usr/local/bin/init

# Create runtime directories with correct ownership (no shell needed)
RUN ["/usr/local/bin/init", "--setup-dirs"]

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER 1999:1999

WORKDIR /var/www/html
EXPOSE 9000
STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/init"]
CMD ["php-fpm"]
