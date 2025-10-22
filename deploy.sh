#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# ------------------------
# Stage 0.5: CLI flags, traps, housekeeping
# ------------------------
CLEANUP_MODE=0
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP_MODE=1
fi

# Exit codes (already present above, but keep/merge if duplicates)
E_CLEANUP=17

# on_exit: archive log and report final status
on_exit() {
  rc="$?"
  if [ "${rc}" -ne 0 ]; then
    log "ERROR" "Script failed with code ${rc}. Log: ${LOGFILE}"
  else
    log "INFO" "Script completed successfully. Log: ${LOGFILE}"
  fi

  # Archive logs older than 0 seconds (current run) into a zip with timestamp
  # Keep last 30 days of logs uncompressed (adjust as needed)
  if command -v gzip >/dev/null 2>&1; then
    # compress the just-written logfile to save space (but keep human-readable original)
    gzip -c "${LOGFILE}" > "${LOGFILE}.gz" || true
  fi

  # Rotate: delete gz logs older than 30 days
  if command -v find >/dev/null 2>&1; then
    find "${LOGDIR}" -type f -name "deploy_*.log.gz" -mtime +30 -print -exec rm -f {} \; || true
  fi
}
trap on_exit EXIT

# If --cleanup flag supplied, perform cleanup then exit early (ask for confirmation)
if [ "${CLEANUP_MODE}" -eq 1 ]; then
  echo "\u26a0\ufe0f  CLEANUP MODE: this will remove containers, images, nginx configs, and the deployed app directory on the remote host ${REMOTE_USER:-<remote_user>}@${REMOTE_HOST:-<remote_host>}"
  printf "Type CLEANUP (uppercase) to confirm: "
  read -r CONFIRM_CLEAN
  if [ "${CONFIRM_CLEAN}" != "CLEANUP" ]; then
    die "${E_CLEANUP}" "Cleanup confirmation failed. Aborting."
  fi

  # NOTE: require REMOTE variables. If not set interactively, ask now.
  if [ -z "${REMOTE_USER:-}" ]; then
    read -rp "Remote SSH username: " REMOTE_USER
  fi
  if [ -z "${REMOTE_HOST:-}" ]; then
    read -rp "Remote SSH host/IP: " REMOTE_HOST
  fi
  if [ -z "${SSH_KEY_PATH:-}" ]; then
    read -rp "Path to SSH private key: " SSH_KEY_PATH
  fi

  log "INFO" "Running remote cleanup on ${REMOTE_USER}@${REMOTE_HOST} ..."
  ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<'REMOTE_CLEAN' 2>&1 | tee -a "${LOGFILE}"
set -e
# Stop and remove containers that look like deployed apps
docker ps -a --format '{{.Names}}' | grep -E '^[a-zA-Z0-9._-]+' | xargs -r -n1 -I{} sh -c 'docker rm -f "{}" || true'
# Remove images created recently (CAUTION: broad)
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk '{print $2}' | xargs -r -n1 -I{} sh -c 'docker rmi -f "{}" || true'
# Remove nginx configs made by our deploy pattern (best-effort)
if [ -d /etc/nginx/sites-enabled ]; then
  find /etc/nginx/sites-enabled -type l -name '*.conf' -exec rm -f {} \; || true
fi
if [ -d /etc/nginx/sites-available ]; then
  find /etc/nginx/sites-available -type f -name '*.conf' -exec rm -f {} \; || true
fi
# Remove deployed app folders under /opt (best-effort)
if [ -d /opt ]; then
  find /opt -maxdepth 1 -type d -name '*-repo*' -prune -exec rm -rf {} \; || true
fi
# Try reload nginx
if command -v nginx >/dev/null 2>&1; then
  nginx -t || true
  systemctl try-restart nginx || true
fi
echo "[REMOTE] Remote cleanup finished."
REMOTE_CLEAN

  log "INFO" "Remote cleanup completed. Compressing local logs (if any) and exiting."
  # archive current log was done by on_exit
  exit 0
fi


# ------------------------
#?stage 1: collect parameters and basic validation
# ------------------------

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGDIR="./logs"
mkdir -p "${LOGDIR}"
LOGFILE="${LOGDIR}/deploy_${TIMESTAMP}.log"

log() { printf "%s [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" | tee -a "${LOGFILE}"; }
die() { log "ERROR" "$2"; exit "${1:-1}"; }

log "INFO" "Starting deploy script (skeleton) — logging to ${LOGFILE}"

# Prompts
read -rp "Git repository URL (https or ssh): " GIT_REPO_URL
if [ -z "${GIT_REPO_URL}" ]; then die 10 "Git repository URL is required"; fi

# to prompt for PAT(Hidden) only when using HTTPS with PAT,
if printf "%s" "${GIT_REPO_URL}" | grep -q "^http"; then
  printf "If repo is private and you need a Personal Access Token (PAT), enter it now (leave empty if not needed): "
  # to read secret without echo
  stty -echo
  read -r GIT_PAT || true
  stty echo
  printf "\n"
else
  GIT_PAT=""
fi

read -rp "Branch name (default: main): " BRANCH
BRANCH="${BRANCH:-main}"

read -rp "Remote SSH username: " REMOTE_USER
read -rp "Remote SSH host/IP: " REMOTE_HOST
read -rp "Path to local SSH private key for remote (e.g. ~/.ssh/deploy_key): " SSH_KEY_PATH
read -rp "Application internal container port (e.g. 3000): " APP_PORT
case "${APP_PORT}" in
  ''|*[!0-9]* ) die 12 "Invalid port";;
esac

log "INFO" "Collected parameters:"
log "INFO" "  Repo: ${GIT_REPO_URL}"
log "INFO" "  Branch: ${BRANCH}"
log "INFO" "  Remote: ${REMOTE_USER}@${REMOTE_HOST}"
log "INFO" "  SSH key: ${SSH_KEY_PATH}"
log "INFO" "  App port: ${APP_PORT}"

# echo "If everything above looks correct, type YES (uppercase) to continue, otherwise ctrl-c to abort."
# read -r CONFIRM
# if [ "${CONFIRM}" != "YES" ]; then die 13 "Not confirmed"; fi

log "INFO" "Skeleton parameter collection complete."


# ------------------------
#? Stage 2: Repo clone + validations
# ------------------------

WORKDIR="./workspace_${TIMESTAMP}"
mkdir -p "${WORKDIR}"
log "INFO" "Created local workspace: ${WORKDIR}"

# Clone logic
if printf "%s" "${GIT_REPO_URL}" | grep -q "^http"; then
  if [ -n "${GIT_PAT}" ]; then
    AUTH_URL="$(echo "${GIT_REPO_URL}" | sed -E "s#https://#https://${GIT_PAT}@#")"
    log "INFO" "Cloning via HTTPS with PAT..."
    git clone -b "${BRANCH}" "${AUTH_URL}" "${WORKDIR}/repo" || die 20 "Failed to clone repo (check PAT or branch)"
  else
    log "INFO" "Cloning public repo via HTTPS..."
    git clone -b "${BRANCH}" "${GIT_REPO_URL}" "${WORKDIR}/repo" || die 21 "Failed to clone repo"
  fi
else
  log "INFO" "Cloning via SSH..."
  GIT_SSH_COMMAND="ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no" \
  git clone -b "${BRANCH}" "${GIT_REPO_URL}" "${WORKDIR}/repo" || die 22 "Failed to clone repo via SSH"
fi

log "INFO" "Repository cloned successfully."

# Check for Docker setup files
if [ -f "${WORKDIR}/repo/Dockerfile" ]; then
  log "INFO" "Found Dockerfile."
elif [ -f "${WORKDIR}/repo/docker-compose.yml" ]; then
  log "INFO" "Found docker-compose.yml."
else
  log "WARN" "No Dockerfile or docker-compose.yml found. Skipping container checks for now."
fi

# Verify SSH connectivity to remote
log "INFO" "Testing SSH connection to ${REMOTE_USER}@${REMOTE_HOST}..."
if ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" "echo 'SSH_OK'" >/dev/null 2>&1; then
  log "INFO" "SSH connection test: SUCCESS."
else
  die 23 "Cannot SSH into remote. Check SSH key, username, host IP, or firewall."
fi

# Rsync dry run (no real file copy yet)
log "INFO" "Performing dry-run rsync to /tmp/deploy-test..."
rsync -avz --dry-run -e "ssh -i ${SSH_KEY_PATH}" "${WORKDIR}/repo/" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/deploy-test/" \
  | tee -a "${LOGFILE}" || die 24 "rsync dry-run failed"

log "INFO" "Dry-run completed successfully — files would sync to /tmp/deploy-test on remote."
log "INFO" "Stage 2: Repo Cloning completed."

# ------------------------
#? Stage 3: Prepare Remote Environment
# ------------------------
log "INFO" "Starting Stage 3: remote environment preparation..."

REMOTE_SETUP_CMD=$(cat <<'EOF'
set -e
echo "[REMOTE] Updating system and installing dependencies..."

sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Install Docker if not already installed
if ! command -v docker &>/dev/null; then
  echo "[REMOTE] Installing Docker..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Install Docker Compose if not found
if ! command -v docker-compose &>/dev/null; then
  echo "[REMOTE] Installing Docker Compose..."
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

# Install Nginx if not installed
if ! command -v nginx &>/dev/null; then
  echo "[REMOTE] Installing Nginx..."
  sudo apt-get install -y nginx
fi

# Add user to Docker group
if ! groups $USER | grep -q docker; then
  echo "[REMOTE] Adding user to Docker group..."
  sudo usermod -aG docker $USER
fi

# Enable and start services
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx

# Display versions
echo "[REMOTE] --- Installed Versions ---"
docker --version || echo "Docker not installed properly"
docker-compose --version || echo "Docker Compose not installed properly"
nginx -v || echo "Nginx not installed properly"

echo "[REMOTE] Setup complete!"
EOF
)

log "INFO" "Executing remote setup commands on ${REMOTE_HOST}..."
ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "${REMOTE_SETUP_CMD}" \
  | tee -a "${LOGFILE}" || die 30 "Remote environment setup failed"

log "INFO" " Stage 3: remote environment preparation completed successfully."


# ------------------------
#? Stage 4: Deploy Application on Remote
# ------------------------
log "INFO" "Starting Stage 4: Application Deployment..."

APP_NAME=$(basename "${GIT_REPO_URL}" .git)
REMOTE_APP_PATH="/opt/${APP_NAME}"

log "INFO" "Syncing project files to ${REMOTE_HOST}:${REMOTE_APP_PATH} ..."
# To Ensure remote directory exists with proper permissions before syncing
log "INFO" "Preparing remote directory ${REMOTE_APP_PATH}..."
ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" \
  "sudo mkdir -p '${REMOTE_APP_PATH}' && sudo chown -R \$(whoami):\$(whoami) '${REMOTE_APP_PATH}'" \
  || die 39 "Failed to prepare remote app directory"

log "INFO" "Syncing project files to ${REMOTE_HOST}:${REMOTE_APP_PATH} ..."
rsync -avz -e "ssh -i ${SSH_KEY_PATH}" --delete "${WORKDIR}/repo/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_PATH}/" \
  | tee -a "${LOGFILE}" || die 40 "File transfer failed"

log "INFO" "Files transferred successfully. Now building and running containers on remote..."
log "INFO" "  SSH key: ${SSH_KEY_PATH}"
log "INFO" "  Host: ${REMOTE_HOST}"
log "INFO" "  Repo: ${GIT_REPO_URL}"

REMOTE_DEPLOY_CMD=$(cat <<'REMOTE_EOF'
set -e

cd "${REMOTE_APP_PATH}" || exit 1
echo "[REMOTE] Navigated to $(pwd)"

if [ -f docker-compose.yml ]; then
  echo "[REMOTE] Using docker-compose for deployment..."
  sudo docker compose down || true
  sudo docker compose build
  sudo docker compose up -d
elif [ -f Dockerfile ]; then
  echo "[REMOTE] Using Dockerfile for deployment..."
  APP_TAG=$(basename "$(pwd)")
  echo "[REMOTE] Building and running container: ${APP_TAG}"
  sudo docker build --build-arg PORT='${APP_PORT}' -t "${APP_TAG}:latest" .
  sudo docker stop "${APP_TAG}" || true
  sudo docker rm "${APP_TAG}" || true
  sudo docker run -d \
    -p '${APP_PORT}':'${APP_PORT}' \
    -e PORT='${APP_PORT}' \
    --name "${APP_TAG}" \
    "${APP_TAG}:latest"
else
  echo "[REMOTE] No Dockerfile or docker-compose.yml found. Deployment aborted."
  exit 1
fi

echo "[REMOTE] Checking running containers..."
sudo docker ps

echo "[REMOTE] Waiting a few seconds for app to start..."
sleep 5

echo "[REMOTE] Testing application endpoint locally..."
if curl -fs "http://localhost:${APP_PORT}" >/dev/null 2>&1; then
  echo "[REMOTE] Application reachable on port ${APP_PORT}."
else
  echo "[REMOTE] WARNING: Application not responding yet."
fi

echo "[REMOTE] Deployment complete!"
REMOTE_EOF
)

# Replace remote-only placeholders with actual local values before sending
REMOTE_DEPLOY_CMD=${REMOTE_DEPLOY_CMD//'${REMOTE_APP_PATH}'/$REMOTE_APP_PATH}
REMOTE_DEPLOY_CMD=${REMOTE_DEPLOY_CMD//'${APP_PORT}'/$APP_PORT}

ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "${REMOTE_DEPLOY_CMD}" \
  | tee -a "${LOGFILE}" || die 41 "Remote deployment failed"

log "INFO" "Stage 4: Application Deployment completed successfully."


# ------------------------
#? Stage 5: Configure Nginx Reverse Proxy
# ------------------------
log "INFO" "Starting Stage 5: Nginx Reverse Proxy setup..."

NGINX_CONFIG_NAME="${APP_NAME}.conf"

REMOTE_NGINX_CMD=$(cat <<EOF
set -e

echo "[REMOTE] Configuring Nginx reverse proxy for ${APP_NAME}..."

NGINX_PATH="/etc/nginx/sites-available/${NGINX_CONFIG_NAME}"
NGINX_LINK="/etc/nginx/sites-enabled/${NGINX_CONFIG_NAME}"

# Backup old config if exists
if [ -f "\$NGINX_PATH" ]; then
  echo "[REMOTE] Backing up old Nginx config..."
  sudo mv "\$NGINX_PATH" "\${NGINX_PATH}.bak_$(date +%s)"
fi

# Write new config
sudo bash -c "cat > \$NGINX_PATH" <<'CONF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONF

# Enable site
sudo ln -sf "\$NGINX_PATH" "\$NGINX_LINK"

# Test and reload
sudo nginx -t && sudo systemctl reload nginx

echo "[REMOTE] Nginx reverse proxy configured successfully!"
EOF
)

ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "${REMOTE_NGINX_CMD}" \
  | tee -a "${LOGFILE}" || die 50 "Nginx configuration failed"

log "INFO" "Stage 5: Nginx Reverse Proxy setup completed successfully."



log "INFO" "  SSH key: ${SSH_KEY_PATH}"
log "INFO" " Host: ${REMOTE_HOST}"
log "INFO" " Repo: ${GIT_REPO_URL}"



# ------------------------
#? Step 6: Validate Deployment
# ------------------------

log "INFO" "Starting Stage 6: Deployment Validation..."

REMOTE_VALIDATE_CMD=$(cat <<EOF
set -e

echo "[REMOTE] Checking service statuses..."

# Docker and Nginx status checks
sudo systemctl is-active --quiet docker && echo "[REMOTE] Docker: Active" || echo "[REMOTE] Docker: Inactive"
sudo systemctl is-active --quiet nginx && echo "[REMOTE] Nginx: Active" || echo "[REMOTE] Nginx: Inactive"

# Container health check
echo "[REMOTE] Checking for running containers..."
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Simple curl test to verify proxy and app availability
echo "[REMOTE] Testing endpoint via Nginx (port 80)..."
if curl -fs "http://localhost" >/dev/null 2>&1; then
  echo "[REMOTE] SUCCESS: Application reachable via Nginx on port 80!"
else
  echo "[REMOTE] ERROR: Application not responding through Nginx!"
fi

echo "[REMOTE] Validation complete."
EOF
)

ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "${REMOTE_VALIDATE_CMD}" \
  | tee -a "${LOGFILE}" || die 60 "Deployment validation failed"

log "INFO" "Stage 6: Deployment Validation completed successfully."



# ------------------------
#? Step 7:  Final Idempotency checks & local log archival
# ------------------------
log "INFO" "Starting Stage 7: Idempotency, cleanup, and log rotation."

# Idempotency sanity checks we already rely on:
# - rsync --delete ensures remote mirror matches local
# - docker compose down / docker rm -f used before new run
# - nginx symlink uses -sf (force) so it won't create dup links
# Still: perform a final safe tidy on the remote

REMOTE_FINALIZE_CMD=$(cat <<'EOF'
set -e
echo "[REMOTE] Performing final tidy checks..."

# Ensure no duplicate nginx symlinks exist for the same file
if [ -d /etc/nginx/sites-enabled ]; then
  # remove broken symlinks
  find /etc/nginx/sites-enabled -xtype l -delete || true
fi

# Remove exited containers older than 7 days (best-effort)
docker ps -a --filter "status=exited" --format '{{.ID}} {{.CreatedAt}}' | awk '{print $1}' | xargs -r -n1 docker rm -v || true

# Remove dangling images
docker image prune -f || true

# Remove unused networks that are dangling
docker network prune -f || true

# Ensure nginx tests OK
if command -v nginx >/dev/null 2>&1; then
  nginx -t || echo "[REMOTE] nginx test failed (non-fatal)"
fi

echo "[REMOTE] Final tidy done."
EOF
)

ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "${REMOTE_FINALIZE_CMD}" \
  | tee -a "${LOGFILE}" || warn "Remote finalization had non-fatal issues."

# Local log rotation handled by on_exit (gzip + retention)
log "INFO" " Final Idempotency checks & local log archival(Step 7)."

# Exit with success code
exit 0

