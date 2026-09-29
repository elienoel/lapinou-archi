#!/usr/bin/env bash
#
# Redeploy the Lapinou backend by pulling the latest source from git and
# rebuilding the Docker image directly on the server (no external registry:
# the backend repo is private, so the image is never pushed anywhere).
# Run this on the server after setup-server.sh has been run once.
# This is also the script the GitHub Actions workflow runs over SSH.
#
# Usage:
#   ./deploy.sh [--deploy-path /opt/lapinou]

set -euo pipefail

DEPLOY_PATH="/opt/lapinou"

while [ $# -gt 0 ]; do
    case "$1" in
        --deploy-path) DEPLOY_PATH="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

DOCKER="docker"
command -v docker >/dev/null 2>&1 || DOCKER="sudo docker"

# Pick up any infra changes (compose file, nginx template, this script).
cd "$DEPLOY_PATH"
git fetch origin
git checkout "$(git rev-parse --abbrev-ref HEAD)"
git merge --ff-only "origin/$(git rev-parse --abbrev-ref HEAD)"

# Pull the latest backend source.
cd "$DEPLOY_PATH/backend"
git fetch origin
git checkout "$(git rev-parse --abbrev-ref HEAD)"
git merge --ff-only "origin/$(git rev-parse --abbrev-ref HEAD)"
BACKEND_REV="$(git rev-parse --short HEAD)"

cd "$DEPLOY_PATH"
$DOCKER compose -f docker-compose.prod.yml build backend
$DOCKER compose -f docker-compose.prod.yml up -d --no-deps backend
$DOCKER image prune -f

echo "Deployed backend @ ${BACKEND_REV}."
