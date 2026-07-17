#!/bin/bash

# ---------------------------------------------------------------------------
# zapdeploy.sh — Sourced script providing deployment aliases/functions.
#
# Usage:
#   source /path/to/zapdeploy.sh
#   zap-docker-deploy <config.properties>
# ---------------------------------------------------------------------------

zap-docker-deploy() {
  bash -c "$(cat << 'EOF_ZAPDEPLOY'
set -euo pipefail

err() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  echo "Usage: zap-docker-deploy <config.properties> [--tag <version>] [--key <ssh-key>] [--compose <file>]"
  exit 1
}

# Pure bash resolver (no perl, no eval)
resolve_vars() {
  local result="$1"
  local var_name
  # Resolve ${VAR}
  while [[ "$result" =~ \$\{([a-zA-Z_][a-zA-Z_0-9]*)\} ]]; do
    var_name="${BASH_REMATCH[1]}"
    local val="${!var_name:-}"
    result="${result//\$\{${var_name}\}/${val}}"
  done
  # Resolve $VAR
  while [[ "$result" =~ \$([a-zA-Z_][a-zA-Z_0-9]*) ]]; do
    var_name="${BASH_REMATCH[1]}"
    local val="${!var_name:-}"
    result="${result//\$${var_name}/${val}}"
  done
  printf "%s" "$result"
}

CONFIG_FILE=""
SSH_KEY_OVERRIDE=""
TAG_OVERRIDE=""
COMPOSE_FILE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --tag) TAG_OVERRIDE="$2"; shift 2 ;;
    --key) SSH_KEY_OVERRIDE="$2"; shift 2 ;;
    --compose) COMPOSE_FILE_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) [[ -f "$1" ]] && { CONFIG_FILE="$1"; shift; } || usage ;;
    *)  CONFIG_FILE="$1"; shift ;;
  esac
done

[[ -n "$CONFIG_FILE" ]] || err "config file required."
[[ -f "$CONFIG_FILE" ]] || err "config file not found: $CONFIG_FILE"

# ---- parse properties ------------------------------------------------------
ENV_LINES=()
SSH_HOST="" ; SSH_PORT="22" ; SSH_USER="ubuntu" ; SSH_KEY="" ; REMOTE_DIR=""
IMAGE_REPO="" ; DOPPLER_PROJECT="" ; DOPPLER_CONFIG=""
INIT_POSTGRES_DSN="" ; DOCKER_NETWORK=""
CADDY_SITE_TEMPLATE="" ; CADDY_DOMAIN="" ; CADDY_SITES_DIR="/opt/caddy/sites" ; CADDY_CONTAINER="caddy"
HEALTHCHECK_TYPE="none" ; HEALTHCHECK_TARGET=""
COMPOSE_FILE_LOCAL="docker-compose.yml"
UPLOAD_FILES=""
ENSURE_DIRS=""

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}" # strip leading space
  [[ -z "$line" || "$line" == '#'* ]] && continue
  [[ "$line" != *=* ]] && continue
  key="${line%%=*}"
  key="${key%"${key##*[![:space:]]}"}" # strip trailing space from key
  value="${line#*=}"
  
  if [[ "$key" == ENV.* ]]; then
    ENV_LINES+=("${key#ENV.}=${value}")
    if [[ "${key#ENV.}" == "IMAGE_REPO" ]]; then
      IMAGE_REPO="$value"
    fi
  else
    case "$key" in
      SSH_HOST)             SSH_HOST="$value" ;;
      SSH_PORT)             SSH_PORT="$value" ;;
      SSH_USER)             SSH_USER="$value" ;;
      SSH_KEY)              SSH_KEY="$value" ;;
      REMOTE_DIR)           REMOTE_DIR="$value" ;;
      IMAGE_REPO)           IMAGE_REPO="$value" ;;
      DOPPLER_PROJECT)      DOPPLER_PROJECT="$value" ;;
      DOPPLER_CONFIG)       DOPPLER_CONFIG="$value" ;;
      INIT_POSTGRES_DSN)    INIT_POSTGRES_DSN="$value" ;;
      DOCKER_NETWORK)       DOCKER_NETWORK="$value" ;;
      CADDY_SITE_TEMPLATE)  CADDY_SITE_TEMPLATE="$value" ;;
      CADDY_DOMAIN)         CADDY_DOMAIN="$value" ;;
      CADDY_SITES_DIR)      CADDY_SITES_DIR="$value" ;;
      CADDY_CONTAINER)      CADDY_CONTAINER="$value" ;;
      HEALTHCHECK_TYPE)     HEALTHCHECK_TYPE="$value" ;;
      HEALTHCHECK_TARGET)   HEALTHCHECK_TARGET="$value" ;;
      COMPOSE_FILE_LOCAL)   COMPOSE_FILE_LOCAL="$value" ;;
      UPLOAD_FILES)         UPLOAD_FILES="$value" ;;
      ENSURE_DIRS)          ENSURE_DIRS="$value" ;;
    esac
  fi
done < "$CONFIG_FILE"

# ---- check dependencies ----------------------------------------------------
deps=(ssh docker scp)
[[ -n "$DOPPLER_PROJECT" ]] && deps+=(doppler)

echo "==> Checking dependencies..."
missing=0
for cmd in "${deps[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  [OK] $cmd"
  else
    echo "  [MISSING] $cmd is required but not installed."
    missing=1
  fi
done
if [[ $missing -ne 0 ]]; then
  err "Please install missing dependencies before deploying."
fi

# ---- load Doppler secrets (optional) ---------------------------------------
if [[ -n "$DOPPLER_PROJECT" ]]; then
  [[ -n "${DOPPLER_TOKEN:-}" ]] || err "DOPPLER_TOKEN is not exported"
  echo "==> Fetching secrets from Doppler ($DOPPLER_PROJECT / $DOPPLER_CONFIG)"
  DOPPLER_OUT="$(doppler secrets download -p "$DOPPLER_PROJECT" -c "$DOPPLER_CONFIG" --format docker --no-file)"
  set -a; eval "$DOPPLER_OUT"; set +a
  
  # Print Doppler keys successfully loaded (as user requested earlier)
  doppler secrets --only-names -p "$DOPPLER_PROJECT" -c "$DOPPLER_CONFIG"
  echo "✅ Secrets loaded into environment for $DOPPLER_PROJECT ($DOPPLER_CONFIG)"
fi

# ---- resolve regular properties --------------------------------------------
for var in SSH_HOST SSH_PORT SSH_USER SSH_KEY REMOTE_DIR IMAGE_REPO DOPPLER_PROJECT DOPPLER_CONFIG INIT_POSTGRES_DSN DOCKER_NETWORK CADDY_SITE_TEMPLATE CADDY_DOMAIN CADDY_SITES_DIR CADDY_CONTAINER HEALTHCHECK_TYPE HEALTHCHECK_TARGET COMPOSE_FILE_LOCAL UPLOAD_FILES ENSURE_DIRS; do
  val="${!var}"
  if [[ -n "$val" ]]; then
    val="$(resolve_vars "$val")"
    eval "$var=\"\$val\""
    if printf '%s' "$val" | grep -qE '\$\{?[a-zA-Z_][a-zA-Z_0-9]*\}?'; then
      err "Property '$var' references an undefined variable (resolved to '$val')."
    fi
  fi
done

# ---- validate essentials ---------------------------------------------------
[[ -n "$SSH_HOST" ]]   || err "SSH_HOST not set in config"
[[ -n "$REMOTE_DIR" ]] || err "REMOTE_DIR not set in config"

SSH_KEY_FINAL="${SSH_KEY_OVERRIDE:-$SSH_KEY}"
[[ -n "$SSH_KEY_FINAL" ]] || err "SSH_KEY not set"
[[ -f "$SSH_KEY_FINAL" ]] || err "ssh key file not found: $SSH_KEY_FINAL"

COMPOSE_FILE="${COMPOSE_FILE_OVERRIDE:-$COMPOSE_FILE_LOCAL}"
[[ -f "$COMPOSE_FILE" ]] || err "compose file not found: $COMPOSE_FILE"

SSH_PORT_ARGS=()
[[ -n "$SSH_PORT" ]] && SSH_PORT_ARGS=("-p" "$SSH_PORT")
SSH_CMD=(ssh "${SSH_PORT_ARGS[@]}" -i "$SSH_KEY_FINAL" -o StrictHostKeyChecking=accept-new "$SSH_USER@$SSH_HOST")
echo "==> Target: $SSH_USER@$SSH_HOST:$REMOTE_DIR"

# ---- resolve ENV.* -> tmp .env ---------------------------------------------
RESOLVED_ENV="$(mktemp 2>/dev/null || mktemp -t deploy-env)"
trap 'rm -f "$RESOLVED_ENV"' EXIT

for line in "${ENV_LINES[@]}"; do
  key="${line%%=*}"
  raw="${line#*=}"
  val="$(resolve_vars "$raw")"
  
  if printf '%s' "$val" | grep -qE '\$\{?[a-zA-Z_][a-zA-Z_0-9]*\}?'; then
    err "ENV.$key references an undefined variable (resolved to '$val')."
  fi
  export "$key=$val"
  printf '%s=%s\n' "$key" "$val" >> "$RESOLVED_ENV"
done

# ---- determine generic IMAGE_TAG -------------------------------------------
if [[ -z "$TAG_OVERRIDE" ]]; then
  TAG_OVERRIDE="$(grep -E '^IMAGE_TAG=' "$RESOLVED_ENV" | head -1 | cut -d= -f2- || true)"
  TAG_OVERRIDE="${TAG_OVERRIDE:-latest}"
fi

if grep -q '^IMAGE_TAG=' "$RESOLVED_ENV"; then
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s|^IMAGE_TAG=.*|IMAGE_TAG=$TAG_OVERRIDE|" "$RESOLVED_ENV"
  else
    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=$TAG_OVERRIDE|" "$RESOLVED_ENV"
  fi
else
  printf 'IMAGE_TAG=%s\n' "$TAG_OVERRIDE" >> "$RESOLVED_ENV"
fi
echo "==> Image Tag: $TAG_OVERRIDE"

trap 'echo ""; echo "!!! DEPLOY FAILED !!!"; rm -f "$RESOLVED_ENV"' ERR

# ---- remote setup hooks ----------------------------------------------------
echo "==> Ensuring remote directory exists"
"${SSH_CMD[@]}" "sudo mkdir -p '$REMOTE_DIR' && sudo chown -R \$(whoami) '$REMOTE_DIR'"

if [[ -n "$DOCKER_NETWORK" ]]; then
  echo "==> Ensuring external docker network '$DOCKER_NETWORK' exists"
  "${SSH_CMD[@]}" "docker network inspect '$DOCKER_NETWORK' >/dev/null 2>&1 || docker network create '$DOCKER_NETWORK'"
fi

if [[ -n "$INIT_POSTGRES_DSN" ]]; then
  DSN="$(resolve_vars "$INIT_POSTGRES_DSN")"
  BASE="${DSN%%\?*}"
  PARAMS=""
  [[ "$DSN" == *\?* ]] && PARAMS="?${DSN#*\?}"
  DB_NAME="${BASE##*/}"
  MAINT_DSN="${BASE%/*}/postgres${PARAMS}"
  echo "==> Ensuring database '$DB_NAME' exists"
  "${SSH_CMD[@]}" "docker run --rm alpine/psql '$MAINT_DSN' -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\" | grep -q 1 \
    && echo '    already exists' \
    || { docker run --rm alpine/psql '$MAINT_DSN' -v ON_ERROR_STOP=1 -c 'CREATE DATABASE \"$DB_NAME\"' && echo '    created'; }"
fi

if [[ -n "$CADDY_SITE_TEMPLATE" && -f "$CADDY_SITE_TEMPLATE" ]]; then
  # One snippet file per app — named after the app (REMOTE_DIR basename), NOT
  # after the domain. A CADDY_DOMAIN change then overwrites the same file
  # instead of leaving the old domain being served from a stale snippet.
  APP_NAME="$(basename "$REMOTE_DIR")"
  SITE_NAME="${APP_NAME:-app}.caddy"

  SITE_FILE="$(mktemp 2>/dev/null || mktemp -t site-snippet)"
  {
    echo "# zapdeploy:app=$APP_NAME"
    sed -e "s|{{DOMAIN}}|$CADDY_DOMAIN|g" -e "s|{{CADDY_DOMAIN}}|$CADDY_DOMAIN|g" "$CADDY_SITE_TEMPLATE"
  } > "$SITE_FILE"

  # Upstream line (whitespace-stripped) — used to detect legacy domain-named
  # snippets for this same app that predate the marker/stable-name scheme.
  UPSTREAM_LINE="$(grep -m1 -E '^[[:space:]]*reverse_proxy[[:space:]]' "$SITE_FILE" | tr -d '[:space:]' || true)"

  echo "==> Writing Caddy site snippet ($SITE_NAME -> ${CADDY_DOMAIN:-<no domain>}) and reloading Caddy"
  "${SSH_CMD[@]}" "sudo mkdir -p '$CADDY_SITES_DIR' && sudo tee '$CADDY_SITES_DIR/$SITE_NAME' >/dev/null" < "$SITE_FILE"
  rm -f "$SITE_FILE"

  # Remove stale snippets for this app: any other *.caddy carrying this app's
  # marker, or (legacy files) proxying to the same upstream.
  "${SSH_CMD[@]}" "for f in '$CADDY_SITES_DIR'/*.caddy; do
      [ -e \"\$f\" ] || continue
      [ \"\$(basename \"\$f\")\" = '$SITE_NAME' ] && continue
      if grep -q '^# zapdeploy:app=$APP_NAME\$' \"\$f\" 2>/dev/null; then
        echo \"    removing stale snippet: \$f\"; sudo rm -f \"\$f\"; continue
      fi
      if [ -n '$UPSTREAM_LINE' ] && grep -E '^[[:space:]]*reverse_proxy[[:space:]]' \"\$f\" 2>/dev/null | tr -d '[:space:]' | grep -qxF -- '$UPSTREAM_LINE'; then
        echo \"    removing stale snippet (same upstream): \$f\"; sudo rm -f \"\$f\"
      fi
    done"

  if "${SSH_CMD[@]}" "docker inspect --format '{{.State.Status}}' '$CADDY_CONTAINER' 2>/dev/null" | grep -q running; then
    "${SSH_CMD[@]}" "docker exec '$CADDY_CONTAINER' caddy reload --config /etc/caddy/Caddyfile 2>&1 || docker restart '$CADDY_CONTAINER'"
  else
    echo "    WARNING: Caddy container '$CADDY_CONTAINER' not running."
  fi
fi

# ---- deploy logic ----------------------------------------------------------
echo "==> Archiving current setup"
"${SSH_CMD[@]}" "cd '$REMOTE_DIR' && TS=\$(date +%Y%m%d-%H%M%S) && \
  if ls .env docker-compose*.yml >/dev/null 2>&1; then \
    mkdir -p archive/\$TS && cp -p .env docker-compose*.yml archive/\$TS/ 2>/dev/null || true; \
  fi && \
  { ls -dt archive/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf || true; }"

echo "==> Copying compose file"
"${SSH_CMD[@]}" "cat > '$REMOTE_DIR/docker-compose.yml'" < "$COMPOSE_FILE"

  if [[ -n "$UPLOAD_FILES" ]]; then
    echo "==> Uploading files/directories: $UPLOAD_FILES"
    IFS=',' read -ra FILES_ARRAY <<< "$UPLOAD_FILES"
    SCP_HOST="$SSH_HOST"
    [[ "$SCP_HOST" == *:* ]] && SCP_HOST="[$SCP_HOST]"
    SCP_PORT_ARGS=()
    [[ -n "$SSH_PORT" ]] && SCP_PORT_ARGS=("-P" "$SSH_PORT")
    for entry in "${FILES_ARRAY[@]}"; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -z "$entry" ]] && continue

      # Each entry is either:
      #   src            -> uploads to $REMOTE_DIR/ (backward compatible;
      #                      works for files and directories via scp -r)
      #   src:dest       -> uploads a single file to an arbitrary absolute
      #                      dest path. Creates the dest dir with sudo and
      #                      writes via `sudo tee` so root-owned targets
      #                      (e.g. /opt/caddy/pki/agent-ca.crt) work without
      #                      the SSH user owning the destination. src must be
      #                      a regular file (not a directory) in this form.
      src="$entry"
      dest=""
      if [[ "$entry" == *:* ]]; then
        src="${entry%%:*}"
        dest="${entry#*:}"
      fi
      src="${src#"${src%%[![:space:]]*}"}"
      src="${src%"${src##*[![:space:]]}"}"
      dest="${dest#"${dest%%[![:space:]]*}"}"
      dest="${dest%"${dest##*[![:space:]]}"}"

      if [[ -z "$dest" ]]; then
        scp "${SCP_PORT_ARGS[@]}" -i "$SSH_KEY_FINAL" -o StrictHostKeyChecking=accept-new -r "$src" "$SSH_USER@$SCP_HOST:$REMOTE_DIR/"
      else
        [[ -f "$src" ]] || err "UPLOAD_FILES dest-path form requires a regular file (not a directory): '$src'"
        echo "    $src -> $dest (via sudo)"
        "${SSH_CMD[@]}" "sudo mkdir -p '$(dirname "$dest")' && sudo tee '$dest' >/dev/null" < "$src"
      fi
    done
  fi

  # ---- ensure mount target dirs exist with required ownership ----------------
  # Comma-separated entries of `path:owner:group[:mode]`. Owner/group are
  # numeric uids/gids (or names resolvable on the remote). Mode is optional,
  # defaults to 755. Example:
  #   ENSURE_DIRS=/opt/zap-controlplane/artifacts:1000:1000:755
  if [[ -n "$ENSURE_DIRS" ]]; then
    echo "==> Ensuring mount target directories exist"
    IFS=',' read -ra DIRS_ARRAY <<< "$ENSURE_DIRS"
    for entry in "${DIRS_ARRAY[@]}"; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -z "$entry" ]] && continue

      # Split on ':'. Expect path:owner:group[:mode].
      IFS=':' read -r dir owner group mode <<< "$entry"
      dir="${dir#"${dir%%[![:space:]]*}"}"
      dir="${dir%"${dir##*[![:space:]]}"}"
      [[ -n "$dir" ]] || err "ENSURE_DIRS entry '$entry' has no path"
      [[ -n "$owner" && -n "$group" ]] || err "ENSURE_DIRS entry '$dir' must specify owner:group"
      [[ -n "$mode" ]] || mode="755"

      echo "    $dir (owner $owner:$group, mode $mode)"
      "${SSH_CMD[@]}" "sudo mkdir -p '$dir' && sudo chown -R '$owner:$group' '$dir' && sudo chmod '$mode' '$dir'"
    done
  fi

echo "==> Starting containers (in-memory .env via tmpfs)"

"${SSH_CMD[@]}" '
  set -e
  TMPFILE=$(mktemp -p /dev/shm 2>/dev/null || mktemp)
  trap "rm -f \"$TMPFILE\"" EXIT
  cat > "$TMPFILE"
  cd "'"$REMOTE_DIR"'"
  docker compose --env-file "$TMPFILE" pull
  docker compose --env-file "$TMPFILE" up -d
' < "$RESOLVED_ENV"

# ---- health check ----------------------------------------------------------
if [[ "$HEALTHCHECK_TYPE" == "docker" ]]; then
  echo "==> Waiting for $HEALTHCHECK_TARGET to become healthy..."
  STATUS="unknown"
  for ((i=1; i<=40; i++)); do
    STATUS=$("${SSH_CMD[@]}" "docker inspect -f '{{.State.Health.Status}}' '$HEALTHCHECK_TARGET' 2>/dev/null" || echo unknown)
    [[ "$STATUS" == "healthy" ]] && break
    sleep 10
  done
  if [[ "$STATUS" != "healthy" ]]; then
    echo "ERROR: $HEALTHCHECK_TARGET not healthy. Logs:"
    "${SSH_CMD[@]}" "docker logs '$HEALTHCHECK_TARGET' 2>&1 | tail -20"
    exit 1
  fi
elif [[ "$HEALTHCHECK_TYPE" == "curl" ]]; then
  echo "==> Waiting for app to answer at $HEALTHCHECK_TARGET"
  UP=false
  for i in $(seq 1 24); do
    if "${SSH_CMD[@]}" "curl -s -o /dev/null --timeout 5 '$HEALTHCHECK_TARGET'" 2>/dev/null; then
      UP=true; break
    fi
    sleep 5
  done
  if [[ "$UP" != true ]]; then
    echo "ERROR: Target did not answer."
    exit 1
  fi
fi

# ---- cleanup old images ----------------------------------------------------
if [[ -n "$IMAGE_REPO" ]]; then
  echo "==> Removing old app images for $IMAGE_REPO"
  if [[ -n "$TAG_OVERRIDE" ]]; then
    "${SSH_CMD[@]}" "docker images '$IMAGE_REPO' --format '{{.Repository}}:{{.Tag}}' | grep -v ':${TAG_OVERRIDE}\$' | xargs -r docker rmi 2>/dev/null || true"
  else
    "${SSH_CMD[@]}" "docker image prune -a --filter 'label=repo=$IMAGE_REPO' -f" >/dev/null 2>&1 || true
  fi
fi

echo "==> App answering on $CADDY_DOMAIN. Deployed $IMAGE_REPO:$TAG_OVERRIDE"
echo "==> Deploy Completed Successfully!"

EOF_ZAPDEPLOY
)" -- "$@"
}

# If executed directly as a script, run the function.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${ZSH_VERSION:-}" ]]; then
  zap-docker-deploy "$@"
else
  if command -v docker >/dev/null 2>&1 && command -v ssh >/dev/null 2>&1; then
    echo "==> [OK] Dependency check passed (docker, ssh found)."
  else
    echo "==> [WARNING] Basic dependencies (docker, ssh) are missing."
  fi
  echo "==> Command 'zap-docker-deploy' is ready!"
fi
