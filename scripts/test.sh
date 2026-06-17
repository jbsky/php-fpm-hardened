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

# Healthcheck (FPM ping via Go init binary)
check "FPM ping/pong (init --healthcheck)" \
  "docker exec ${CONTAINER} /usr/local/bin/init --healthcheck && echo 'pong'" \
  "pong"

# Required extensions for WordPress
for ext in gd imagick mysqli zip bz2 intl exif bcmath gmp redis curl sodium; do
  check "Extension: ${ext}" \
    "docker exec ${CONTAINER} php -m 2>/dev/null" \
    "${ext}"
done

# OPcache (listed as "Zend OPcache" in php -m)
check "Extension: opcache" \
  "docker exec ${CONTAINER} php -m 2>/dev/null" \
  "Zend OPcache"

# PHP version
check "PHP 8.5.x" \
  "docker exec ${CONTAINER} php -v 2>/dev/null | head -1" \
  "PHP 8.5"

# expose_php disabled
check "expose_php = Off" \
  "docker exec ${CONTAINER} php -i 2>/dev/null | grep 'expose_php'" \
  "Off"

# Dangerous functions disabled
check "exec disabled" \
  "docker exec ${CONTAINER} php -r 'echo ini_get(\"disable_functions\");' 2>/dev/null" \
  "exec"

# Non-root (check via docker inspect — no 'id' binary in FROM scratch)
check "Running as non-root (uid 1999)" \
  "docker inspect -f '{{.Config.User}}' ${CONTAINER}" \
  "1999"

# Read-only filesystem
check "Root filesystem read-only" \
  "docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' ${CONTAINER}" \
  "true"

# No new privileges
check "No new privileges" \
  "docker inspect -f '{{.HostConfig.SecurityOpt}}' ${CONTAINER}" \
  "no-new-privileges"

# OPcache JIT enabled (check via FPM, not CLI — JIT is FPM-only unless opcache.enable_cli=1)
check "OPcache JIT configured" \
  "docker exec ${CONTAINER} php -i 2>/dev/null | grep 'opcache.jit '" \
  "tracing"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
