#!/usr/bin/env bash
# =====================================================================
#  test.sh — Smoke tests pour php-fpm-hardened
# =====================================================================
set -euo pipefail

CONTAINER="${1:-php-fpm-hardened}"

# Tout passe par php-fpm, jamais par le CLI php : celui-ci n'est pas embarque
# (28,8 Mo inutiles au service). php-fpm accepte -m, -v, -i et -d ; il n'a pas
# -r, donc les assertions se lisent dans la sortie de `php-fpm -i`.
PASS=0
FAIL=0

# Executer du PHP dans l'image sans CLI : on parle FastCGI, exactement comme
# nginx en production. `docker cp` n'a besoin d'aucun shell dans le conteneur
# (l'image est FROM scratch), et le client cgi-fcgi vit dans un conteneur
# jetable qui partage la pile reseau du conteneur teste. C'est le seul moyen
# d'obtenir une assertion FONCTIONNELLE : `php-fpm -m` et `php-fpm -i` se
# contentent de ce que l'extension declare, pas de ce qu'elle sait faire.
fcgi_eval() {
  local code="$1" tmp
  tmp=$(mktemp -d)
  printf '<?php %s' "${code}" > "${tmp}/__smoke.php"
  if ! docker cp "${tmp}/__smoke.php" "${CONTAINER}:/var/www/html/__smoke.php" >/dev/null 2>&1; then
    rm -rf "${tmp}"
    echo "__FAIL__ docker cp"
    return 0
  fi
  docker run --rm --network "container:${CONTAINER}" alpine:3.24 sh -c \
    'apk add --no-cache fcgi >/dev/null 2>&1; \
     SCRIPT_FILENAME=/var/www/html/__smoke.php REQUEST_METHOD=GET \
     cgi-fcgi -bind -connect 127.0.0.1:9000' 2>/dev/null
  rm -rf "${tmp}"
}

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
# Cette liste doit suivre le Dockerfile, sinon le test recale une image
# correcte -- arrive le 2026-08-28 avec intl, ce qui a bloque la publication
# pendant 24 h. intl y est revenue le 30/08 (module recommande par Site
# Health) : sa presence dans `php-fpm -m` ne prouve rien, voir le test
# fonctionnel plus bas.
for ext in gd imagick intl mysqli zip bz2 exif bcmath gmp redis curl sodium; do
  check "Extension: ${ext}" \
    "docker exec ${CONTAINER} php-fpm -m 2>/dev/null" \
    "${ext}"
done

# OPcache (listed as "Zend OPcache" in php-fpm -m)
check "Extension: opcache" \
  "docker exec ${CONTAINER} php-fpm -m 2>/dev/null" \
  "Zend OPcache"

# PHP version
check "PHP 8.5.x" \
  "docker exec ${CONTAINER} php-fpm -v 2>/dev/null | head -1" \
  "PHP 8.5"

# expose_php disabled
check "expose_php = Off" \
  "docker exec ${CONTAINER} php-fpm -i 2>/dev/null | grep 'expose_php'" \
  "Off"

# Dangerous functions disabled
check "exec disabled" \
  "docker exec ${CONTAINER} php-fpm -i 2>/dev/null | grep '^disable_functions'" \
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
  "docker exec ${CONTAINER} php-fpm -i 2>/dev/null | grep 'opcache.jit '" \
  "tracing"

# ---------------------------------------------------------------------
#  Assertions fonctionnelles (via FastCGI, cf. fcgi_eval)
# ---------------------------------------------------------------------

# Sanity : si la plomberie FastCGI casse, les tests suivants echouent tous.
# Celui-ci dit lequel des deux est en cause.
check "FastCGI: execution d'un script" \
  "fcgi_eval 'echo \"FCGI_OK\";'" \
  "FCGI_OK"

# intl : les donnees ICU sont un fichier de DONNEES que rien n'enumere.
# Supprimees, l'extension se charge quand meme et `php-fpm -i` affiche encore
# "ICU Data version" -- seul un appel reel meurt (IntlException, exit 255).
check "intl: Collator fr_FR (donnees ICU reellement chargees)" \
  "fcgi_eval 'echo \"COLLATOR=\", (new Collator(\"fr_FR\"))->compare(\"a\", \"b\");'" \
  "COLLATOR=-1"

check "intl: idn_to_ascii (UTS46, u umlaut -> punycode)" \
  "fcgi_eval 'echo \"IDN=\", idn_to_ascii(\"b\\u{00FC}cher.de\");'" \
  "IDN=xn--bcher-kva.de"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
