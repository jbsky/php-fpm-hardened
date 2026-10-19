#!/usr/bin/env bash
# =====================================================================
#  deploy.sh — build / scan / sbom helper
# =====================================================================
set -euo pipefail

NAME="php-fpm-hardened"
# Meme reference que docker-compose.yml : la forge GitLab est morte.
IMAGE="${IMAGE:-docker.io/jbsky/${NAME}:latest}"

case "${1:-build}" in
  build)
    echo "==> Building ${IMAGE}"
    docker compose build --pull
    ;;
  scan)
    echo "==> Trivy scan ${IMAGE}"
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      aquasec/trivy:latest image \
      --severity HIGH,CRITICAL --ignore-unfixed \
      "${IMAGE}"
    ;;
  sbom)
    echo "==> SBOM generation (syft)"
    mkdir -p sbom
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      anchore/syft:latest \
      "${IMAGE}" -o spdx-json > "sbom/${NAME}.spdx.json"
    echo "SBOM saved to sbom/${NAME}.spdx.json"
    ;;
  *)
    echo "Usage: $0 {build|scan|sbom}"
    exit 1
    ;;
esac
