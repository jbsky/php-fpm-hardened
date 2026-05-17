# =====================================================================
#  PHP-FPM Hardened — Multi-stage build (WordPress-optimized)
#  - Stage 1 (builder):  Compile PHP extensions from source
#  - Stage 2 (production): Runtime minimal Alpine
#
#  Extensions: opcache, gd, imagick, mysqli, zip, bz2, intl, exif,
#              bcmath, gmp, sodium, redis, curl
#
#  Proxy-aware: passe http_proxy/https_proxy via les predefined ARGs
#  BuildKit (non baked dans l'image finale).
# =====================================================================

# ---------------------------------------------------------------------------
# Stage 1: builder — compile les extensions PHP
# ---------------------------------------------------------------------------
FROM php:8.4-fpm-alpine AS builder

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
      opcache \
      zip

# Imagick from PECL (stable release)
RUN pecl install imagick && \
    docker-php-ext-enable imagick

# Redis from PECL
RUN pecl install redis && \
    docker-php-ext-enable redis

# Record versions for downstream
RUN php -v | head -1 | awk '{print $2}' > /tmp/PHP_VER && \
    php -r 'echo phpversion("imagick");' > /tmp/IMAGICK_VER && \
    php -r 'echo phpversion("redis");' > /tmp/REDIS_VER && \
    echo "php=$(cat /tmp/PHP_VER) imagick=$(cat /tmp/IMAGICK_VER) redis=$(cat /tmp/REDIS_VER)" > /tmp/image-versions

# ---------------------------------------------------------------------------
# Stage 2: production — runtime minimal
# ---------------------------------------------------------------------------
FROM php:8.4-fpm-alpine AS production

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

LABEL org.opencontainers.image.title="php-fpm-hardened" \
      org.opencontainers.image.description="Hardened PHP-FPM 8.4 Alpine — WordPress-optimized" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.licenses="MIT"

# Runtime deps only (no compilers, no build tools)
RUN apk add --no-cache \
    ca-certificates curl fcgi freetype gmp icu-libs imagemagick-libs \
    libbz2 libjpeg-turbo libpng libwebp libxml2 libzip oniguruma \
    pcre2 tzdata zlib && \
    # Create non-root user
    addgroup -g 1999 -S phpfpm && \
    adduser -S -D -H -u 1999 -h /var/www/html -s /sbin/nologin -G phpfpm phpfpm && \
    # Create required dirs
    mkdir -p /var/www/html /var/log/php-fpm /var/run/php-fpm \
             /usr/local/etc/php/conf.d && \
    chown -R phpfpm:phpfpm /var/www/html /var/log/php-fpm /var/run/php-fpm && \
    # Symlink logs to stdout/stderr
    ln -sf /dev/stderr /var/log/php-fpm/error.log

# Copy compiled extensions from builder
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
COPY --from=builder /tmp/image-versions /etc/image-versions

# Copy configuration
COPY --chown=root:phpfpm conf/php/php-hardened.ini /usr/local/etc/php/conf.d/zz-hardened.ini
COPY --chown=root:phpfpm conf/php/opcache.ini /usr/local/etc/php/conf.d/zz-opcache.ini
COPY --chown=root:phpfpm conf/php/wordpress.ini /usr/local/etc/php/conf.d/zz-wordpress.ini
COPY --chown=root:phpfpm conf/fpm/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY --chown=root:phpfpm conf/fpm/docker.conf /usr/local/etc/php-fpm.d/docker.conf
COPY --chown=root:phpfpm conf/fpm/php-fpm.conf /usr/local/etc/php-fpm.conf

# Copy entrypoint
COPY --chmod=755 scripts/entrypoint.sh /entrypoint.sh

# Harden: remove default configs, fix permissions
RUN rm -f /usr/local/etc/php-fpm.d/zz-docker.conf && \
    chmod 644 /usr/local/etc/php/conf.d/*.ini && \
    chmod 644 /usr/local/etc/php-fpm.d/*.conf && \
    chmod 644 /usr/local/etc/php-fpm.conf && \
    # Remove PHP version exposure
    rm -f /usr/local/etc/php/php.ini-development /usr/local/etc/php/php.ini-production && \
    # Ensure PID file is writable
    touch /var/run/php-fpm/php-fpm.pid && chown phpfpm:phpfpm /var/run/php-fpm/php-fpm.pid

# Healthcheck via FPM status page (fcgi)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET \
        cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q pong || exit 1

WORKDIR /var/www/html
EXPOSE 9000
STOPSIGNAL SIGQUIT
USER phpfpm
ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
