#!/usr/bin/env bash
#
# One-time production server setup for the Lapinou backend.
# Run this ONCE on a fresh Ubuntu/Debian server (as a user with sudo rights).
#
# It installs Docker, clones the infra repo (docker-compose.prod.yml +
# deploy/) and the backend app repo (source + Dockerfile), generates the
# .env file, builds the backend image locally, and obtains a Let's Encrypt
# SSL certificate via Nginx + Certbot.
#
# Both repos are private, so the server needs its own git credentials for
# each (SSH deploy key, or an HTTPS URL containing a token) -- see --repo
# and --backend-repo below. There is no Docker registry involved: the image
# is built on the server itself and never pushed/pulled anywhere.
#
# Sensitive values (DB password, Django secret key) are NEVER hardcoded
# here: pass them as flags, or leave them out and you will be prompted for
# them with hidden input.
#
# Usage example:
#   ./setup-server.sh \
#     --domain api.lapinou.example \
#     --email admin@lapinou.example
#
# (DB password / secret key will then be prompted interactively.)

set -euo pipefail

# ---------- Defaults ----------
# Infra repo: contains docker-compose.prod.yml + deploy/ at its root.
REPO_URL="https://github.com/elienoel/lapinou-archi.git"
# Backend app repo: contains the Django source + Dockerfile.
BACKEND_REPO_URL="https://github.com/elienoel/lapinou-backend.git"
BRANCH="prod"
DEPLOY_PATH="/opt/lapinou"
DB_NAME="lapinou"
DB_USER="lapinou"
DB_PASSWORD=""
SECRET_KEY=""
DOMAIN=""
EMAIL=""
ALLOWED_HOSTS=""

# ---------- Parse arguments ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --repo) REPO_URL="$2"; shift 2 ;;
        --backend-repo) BACKEND_REPO_URL="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --deploy-path) DEPLOY_PATH="$2"; shift 2 ;;
        --db-name) DB_NAME="$2"; shift 2 ;;
        --db-user) DB_USER="$2"; shift 2 ;;
        --db-password) DB_PASSWORD="$2"; shift 2 ;;
        --secret-key) SECRET_KEY="$2"; shift 2 ;;
        --allowed-hosts) ALLOWED_HOSTS="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------- Prompt for anything required but missing ----------
[ -z "$DOMAIN" ] && read -r -p "Domain name (e.g. api.lapinou.example): " DOMAIN
[ -z "$EMAIL" ] && read -r -p "Email for Let's Encrypt renewal notices: " EMAIL
[ -z "$ALLOWED_HOSTS" ] && ALLOWED_HOSTS="$DOMAIN"

if [ -z "$DB_PASSWORD" ]; then
    read -r -s -p "PostgreSQL password for user '$DB_USER': " DB_PASSWORD
    echo
fi

if [ -z "$SECRET_KEY" ]; then
    read -r -s -p "Django SECRET_KEY (leave empty to auto-generate): " SECRET_KEY
    echo
    if [ -z "$SECRET_KEY" ]; then
        SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(50))' 2>/dev/null || openssl rand -base64 50)"
        echo "Generated a random SECRET_KEY."
    fi
fi

echo
echo "== Configuration summary =="
echo "Domain:         $DOMAIN"
echo "Deploy path:    $DEPLOY_PATH"
echo "Infra repo:     $REPO_URL @ $BRANCH"
echo "Backend repo:   $BACKEND_REPO_URL @ $BRANCH"
echo "DB name/user:   $DB_NAME / $DB_USER"
echo

# ---------- 1. Install base packages (git, envsubst) ----------
if ! command -v git >/dev/null 2>&1 || ! command -v envsubst >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends git gettext-base
fi

# ---------- 2. Install Docker ----------
if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    echo "Docker installed. You may need to log out/in for group changes to apply."
else
    echo "Docker already installed, skipping."
fi

DOCKER="sudo docker"
if groups "$USER" | grep -qw docker; then
    DOCKER="docker"
fi

# ---------- 3. Clone or update the infra repo ----------
if [ -d "$DEPLOY_PATH/.git" ]; then
    echo "Infra repo already present at $DEPLOY_PATH, pulling latest $BRANCH..."
    git -C "$DEPLOY_PATH" fetch origin "$BRANCH"
    git -C "$DEPLOY_PATH" checkout "$BRANCH"
    git -C "$DEPLOY_PATH" pull origin "$BRANCH"
else
    echo "Cloning $REPO_URL ($BRANCH) into $DEPLOY_PATH..."
    sudo mkdir -p "$(dirname "$DEPLOY_PATH")"
    sudo git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_PATH"
    sudo chown -R "$USER":"$USER" "$DEPLOY_PATH"
fi

# ---------- 4. Clone or update the backend app repo ----------
BACKEND_PATH="$DEPLOY_PATH/backend"
if [ -d "$BACKEND_PATH/.git" ]; then
    echo "Backend repo already present at $BACKEND_PATH, pulling latest $BRANCH..."
    git -C "$BACKEND_PATH" fetch origin "$BRANCH"
    git -C "$BACKEND_PATH" checkout "$BRANCH"
    git -C "$BACKEND_PATH" pull origin "$BRANCH"
else
    echo "Cloning $BACKEND_REPO_URL ($BRANCH) into $BACKEND_PATH..."
    git clone --branch "$BRANCH" "$BACKEND_REPO_URL" "$BACKEND_PATH"
fi

cd "$DEPLOY_PATH"

# ---------- 5. Generate .env ----------
cat > .env <<EOF
DEBUG=False
SECRET_KEY=${SECRET_KEY}
ALLOWED_HOSTS=${ALLOWED_HOSTS}
CSRF_TRUSTED_ORIGINS=https://${DOMAIN}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DOMAIN=${DOMAIN}
EOF
chmod 600 .env
echo ".env written to $DEPLOY_PATH/.env"

# ---------- 6. Generate nginx.conf from template ----------
DOMAIN="$DOMAIN" envsubst '${DOMAIN}' < deploy/nginx.conf.template > deploy/nginx.conf
echo "deploy/nginx.conf generated for domain $DOMAIN"

# ---------- 7. Build the backend image ----------
$DOCKER compose -f docker-compose.prod.yml build backend

# ---------- 8. Bootstrap a self-signed cert so Nginx can start ----------
$DOCKER compose -f docker-compose.prod.yml run --rm --entrypoint \
  "mkdir -p /etc/letsencrypt/live/$DOMAIN" certbot

$DOCKER compose -f docker-compose.prod.yml run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
  -keyout /etc/letsencrypt/live/$DOMAIN/privkey.pem \
  -out /etc/letsencrypt/live/$DOMAIN/fullchain.pem \
  -subj /CN=localhost" certbot

# ---------- 9. Start db, backend, nginx (with the temporary cert) ----------
$DOCKER compose -f docker-compose.prod.yml up -d db backend nginx

# ---------- 10. Replace the dummy cert with a real Let's Encrypt cert ----------
$DOCKER compose -f docker-compose.prod.yml run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN /etc/letsencrypt/renewal/$DOMAIN.conf" certbot

$DOCKER compose -f docker-compose.prod.yml run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
  --email $EMAIL -d $DOMAIN --rsa-key-size 4096 --agree-tos --non-interactive" certbot

$DOCKER compose -f docker-compose.prod.yml exec nginx nginx -s reload

# ---------- 11. Start everything, including the certbot renewal loop ----------
$DOCKER compose -f docker-compose.prod.yml up -d

echo
echo "Setup complete. The backend should now be reachable at https://$DOMAIN"
echo "For subsequent deployments (e.g. from CI), use deploy/deploy.sh instead."
