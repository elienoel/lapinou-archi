#!/usr/bin/env bash
#
# Redeploy the Lapinou backend with a new Docker image.
# Run this on the server after setup-server.sh has been run once.
# This is also the script the GitHub Actions workflow runs over SSH.
#
# Usage:
#   ./deploy.sh --image ghcr.io/elienoel/lapinou-backend:<tag> [--deploy-path /opt/lapinou]
#
# GHCR credentials are only needed here if the server isn't already logged in
# (setup-server.sh normally handles that once). Pass them as flags if needed;
# they are never stored in this script.

set -euo pipefail

DEPLOY_PATH="/opt/lapinou"
IMAGE=""
GHCR_USER=""
GHCR_TOKEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --deploy-path) DEPLOY_PATH="$2"; shift 2 ;;
        --ghcr-user) GHCR_USER="$2"; shift 2 ;;
        --ghcr-token) GHCR_TOKEN="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$IMAGE" ]; then
    echo "Missing required --image <ref>" >&2
    exit 1
fi

DOCKER="docker"
command -v docker >/dev/null 2>&1 || DOCKER="sudo docker"

cd "$DEPLOY_PATH"

if [ -n "$GHCR_TOKEN" ] && [ -n "$GHCR_USER" ]; then
    echo "$GHCR_TOKEN" | $DOCKER login ghcr.io -u "$GHCR_USER" --password-stdin
fi

# Pick up any non-code changes (compose file, nginx template) from the deploy branch.
git fetch origin
git checkout "$(git rev-parse --abbrev-ref HEAD)"
git merge --ff-only "origin/$(git rev-parse --abbrev-ref HEAD)"

# Point .env at the new image tag.
if grep -q '^BACKEND_IMAGE=' .env; then
    sed -i.bak "s#^BACKEND_IMAGE=.*#BACKEND_IMAGE=${IMAGE}#" .env && rm -f .env.bak
else
    echo "BACKEND_IMAGE=${IMAGE}" >> .env
fi

$DOCKER compose -f docker-compose.prod.yml pull backend
$DOCKER compose -f docker-compose.prod.yml up -d --no-deps backend
$DOCKER image prune -f

echo "Deployed ${IMAGE}."
