#!/usr/bin/env bash
# =====================================================================
#  test.sh — Smoke tests pour php-fpm-hardened
# =====================================================================
set -euo pipefail

CONTAINER="${1:-php-fpm-hardened}"
PASS=0
FAIL=0

check() {
  local desc="$1" cmd="$2" expected="$3"
  local result
  result=$(eval "$cmd" 2>/dev/null || echo "__FAIL__")
  if echo "$result" | grep -q "$expected"; then
    echo "  [PASS] ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${desc} (got: ${result})"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== PHP-FPM Hardened — Smoke Tests ==="
echo "Container: ${CONTAINER}"
echo ""

# Check container is running
check "Container running" \
  "docker inspect -f '{{.State.Running}}' ${CONTAINER}" \
  "true"

# Healthcheck (FPM ping)
check "FPM ping/pong" \
  "docker exec ${CONTAINER} sh -c 'SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 2>/dev/null | tail -1'" \
  "pong"

# Required extensions for WordPress
for ext in opcache gd imagick mysqli zip bz2 intl exif bcmath gmp redis curl sodium; do
  check "Extension: ${ext}" \
    "docker exec ${CONTAINER} php -m 2>/dev/null" \
    "${ext}"
done

# PHP version
check "PHP 8.4.x" \
  "docker exec ${CONTAINER} php -v 2>/dev/null | head -1" \
  "PHP 8.4"

# expose_php disabled
check "expose_php = Off" \
  "docker exec ${CONTAINER} php -i 2>/dev/null | grep 'expose_php'" \
  "Off"

# Dangerous functions disabled
check "exec disabled" \
  "docker exec ${CONTAINER} php -r 'echo ini_get(\"disable_functions\");' 2>/dev/null" \
  "exec"

# Non-root
check "Running as non-root (uid 1999)" \
  "docker exec ${CONTAINER} id -u" \
  "1999"

# Read-only filesystem
check "Root filesystem read-only" \
  "docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' ${CONTAINER}" \
  "true"

# No new privileges
check "No new privileges" \
  "docker inspect -f '{{.HostConfig.SecurityOpt}}' ${CONTAINER}" \
  "no-new-privileges"

# OPcache JIT enabled
check "OPcache JIT enabled" \
  "docker exec ${CONTAINER} php -r 'echo opcache_get_status()[\"jit\"][\"enabled\"] ? \"yes\" : \"no\";' 2>/dev/null" \
  "yes"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
