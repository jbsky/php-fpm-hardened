#!/bin/sh
# =====================================================================
#  entrypoint.sh — PHP-FPM Hardened entrypoint
#  - Fixes permissions on writable dirs at runtime
#  - Supports WP_ENV overrides (pm tuning, debug)
# =====================================================================
set -e

# --- Fix ownership on volumes (may be mounted as root) ---
for dir in /var/www/html /var/log/php-fpm /var/run/php-fpm /tmp; do
  if [ -d "$dir" ] && [ "$(stat -c %u "$dir")" != "1999" ]; then
    chown -R phpfpm:phpfpm "$dir" 2>/dev/null || true
  fi
done

# --- WordPress debug mode (opt-in via WP_DEBUG=1) ---
if [ "${WP_DEBUG:-0}" = "1" ]; then
  cat > /usr/local/etc/php/conf.d/zz-debug.ini <<'INI'
display_errors = On
display_startup_errors = On
error_reporting = E_ALL
opcache.revalidate_freq = 0
opcache.validate_timestamps = 1
opcache.jit = off
INI
  echo "[entrypoint] WP_DEBUG mode enabled"
fi

# --- PHP-FPM tuning override via env ---
if [ -n "${PHP_PM_MAX_CHILDREN:-}" ]; then
  sed -i "s/^pm.max_children.*/pm.max_children = ${PHP_PM_MAX_CHILDREN}/" \
    /usr/local/etc/php-fpm.d/www.conf
fi
if [ -n "${PHP_MEMORY_LIMIT:-}" ]; then
  echo "memory_limit = ${PHP_MEMORY_LIMIT}" > /usr/local/etc/php/conf.d/zz-memory.ini
fi
if [ -n "${PHP_UPLOAD_MAX_FILESIZE:-}" ]; then
  cat > /usr/local/etc/php/conf.d/zz-upload.ini <<INI
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}
post_max_size = ${PHP_UPLOAD_MAX_FILESIZE}
INI
fi

echo "[entrypoint] PHP $(php -v | head -1 | awk '{print $2}') ready"

exec "$@"
