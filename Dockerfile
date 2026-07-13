# =====================================================================
#  PHP-FPM Hardened — Multi-stage FROM scratch build
#  4-stage: builder -> gobuilder -> prep -> FROM scratch
#  Conformite Docker Hardened Image :
#   - FROM scratch final stage: zero shell, zero package manager
#   - utilisateur non-root (uid 1999)
#   - entrypoint + healthcheck en binaire Go statique (FastCGI PING/PONG)
#   - tini-static PID 1
#
#  Extensions: opcache, gd, imagick, mysqli, zip, bz2, intl, exif,
#              bcmath, gmp, sodium, redis, curl
#
#  Proxy-aware: passe http_proxy/https_proxy via les predefined ARGs
#  BuildKit (non baked dans l'image finale).
# =====================================================================

# ---------------------------------------------------------------------------
# Stage 0: builder — compile PHP extensions from source
# ---------------------------------------------------------------------------
FROM php:8.5.8-fpm-alpine@sha256:79def1d16ece3ab1a6656c46a23bfd80ad33887fbd33626e7bd743cef54ef9c6 AS builder

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

# Configure + compile GD with full format support
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
RUN git clone --depth 1 https://github.com/Imagick/imagick.git /tmp/imagick && \
    cd /tmp/imagick && phpize && ./configure && make -j"$(nproc)" && make install && \
    docker-php-ext-enable imagick && rm -rf /tmp/imagick

# Redis from git (PECL stable not yet available for PHP 8.5)
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
FROM golang:1.26-alpine@sha256:3ad57304ad93bbec8548a0437ad9e06a455660655d9af011d58b993f6f615648 AS gobuilder
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
RUN apk add --no-cache \
    ca-certificates freetype gmp icu-libs imagemagick-libs \
    libbz2 libcurl libjpeg-turbo libpng libwebp libxml2 libzip \
    oniguruma pcre2 tzdata zlib libgcc libstdc++ tini-static \
    readline sqlite-libs argon2-libs gnu-libiconv libsodium

# Create non-root user
RUN addgroup -g 1999 -S phpfpm \
 && adduser -S -D -H -u 1999 -h /var/www/html -s /sbin/nologin -G phpfpm phpfpm

# Copy PHP binaries from builder
COPY --from=builder /usr/local/bin/php /usr/local/bin/php
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
COPY --link --from=prep /lib/ /lib/
COPY --link --from=prep /usr/lib/ /usr/lib/

# PHP binaries
COPY --link --from=prep /usr/local/bin/php /usr/local/bin/php
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
