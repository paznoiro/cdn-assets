#!/bin/bash

# ---------------------------------------------------------------------------
# zaprelease.sh — Sourced script providing a release helper.
#
# Cuts a GitHub Release that triggers the build+deploy pipeline
# (release-docker.yml). It ONLY creates a GitHub Release — no build, no
# version pin, no commit, no push. The release builds from origin/main.
#
# Usage:
#   source /path/to/zaprelease.sh
#   zap-release [--patch|--minor|--major] [--version vX.Y.Z] [--config <file>] [--repo owner/name]
#
# --repo defaults to the owner/name parsed from the git 'origin' remote.
# Every invocation prints the usage format, then asks for confirmation.
# ---------------------------------------------------------------------------

zap-release() {
  bash -c "$(cat << 'EOF_ZAPRELEASE'
set -euo pipefail

err() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: zap-release [options]
  The release builds from origin/main.
  Options:
    --patch              Bump patch version (default)
    --minor              Bump minor version
    --major              Bump major version
    --version <vX.Y.Z>   Use an explicit version instead of bumping
    --config <file>      Deploy from <file> after build (omit = build only)
    --repo <owner/name>  Target GitHub repo (default: parsed from origin remote)
    -h, --help           Show this help and exit

  Examples:
    zap-release                                            # patch, build only
    zap-release --minor                                    # minor, build only
    zap-release --version v2.5.0                           # explicit, build only
    zap-release --config deploy-aiccloud.properties        # patch + deploy
    zap-release --config deploy-oracle.properties --minor  # minor + deploy
    zap-release --repo myorg/myrepo                        # override target repo
USAGE
}

BUMP="patch"
VERSION=""
CONFIG_FILE=""
HAS_CONFIG=0
REPO=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --patch)   BUMP="patch"; shift ;;
    --minor)   BUMP="minor"; shift ;;
    --major)   BUMP="major"; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --config)  CONFIG_FILE="$2"; HAS_CONFIG=1; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; echo; usage; exit 1 ;;
  esac
done

# Always show the usage format first.
usage
echo

command -v gh  >/dev/null || err "gh CLI is required"
command -v git >/dev/null || err "git is required"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || err "not inside a git repository"

# Default the target repo to owner/name parsed from the origin remote.
if [[ -z "$REPO" ]]; then
  ORIGIN_URL="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null)" \
    || err "no 'origin' remote; pass --repo owner/name"
  # Extract owner/name from ssh (git@host:owner/name), https, or ssh:// URLs.
  REPO="$(printf '%s' "${ORIGIN_URL%.git}" | sed -E 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
fi
[[ "$REPO" == */* ]] || err "invalid --repo '$REPO' (expected owner/name)"
ACTIONS_URL="https://github.com/$REPO/actions"
echo "==> Target repo: $REPO"

# Warn about unpushed/uncommitted work: the release builds from origin/main.
# gh uses the HTTPS API, so a failed git fetch (e.g. SSH port 22 blocked) is a
# warning, not fatal — we fall back to local tags/refs.
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "WARNING: uncommitted changes — the release builds from what is pushed to main, not your working tree."
fi
if ! git -C "$ROOT_DIR" fetch --tags --quiet origin 2>/dev/null; then
  echo "WARNING: could not fetch from origin (network/SSH?) — using local tags/refs."
fi
LOCAL_HEAD=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)
REMOTE_HEAD=$(git -C "$ROOT_DIR" rev-parse origin/main 2>/dev/null || true)
if [[ -n "$REMOTE_HEAD" && "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
  echo "WARNING: local HEAD ($LOCAL_HEAD) differs from origin/main ($REMOTE_HEAD) — did you push?"
fi

# ---- compute next version --------------------------------------------------
if [[ -z "$VERSION" ]]; then
  LATEST=$(git -C "$ROOT_DIR" tag -l 'v*' --sort=-v:refname | head -1)
  if [[ -z "$LATEST" ]]; then
    VERSION="v0.1.0"
    echo "==> No v* tag found -> first release: $VERSION"
  else
    IFS='.' read -r MAJ MIN PAT <<< "${LATEST#v}"
    case $BUMP in
      major) VERSION="v$((MAJ + 1)).0.0" ;;
      minor) VERSION="v${MAJ}.$((MIN + 1)).0" ;;
      patch) VERSION="v${MAJ}.${MIN}.$((PAT + 1))" ;;
    esac
  fi
fi
echo "==> Latest tag: ${LATEST:-none} -> new version: $VERSION ($BUMP bump)"

if [[ "$HAS_CONFIG" -eq 1 ]]; then
  # The config is validated relative to the current dir — pass it exactly as the
  # pipeline resolves it (relative to zap-document-api/, e.g. run from there).
  [[ -f "$CONFIG_FILE" ]] || err "config file not found: $CONFIG_FILE (in $(pwd)) — pass it relative to the app dir (zap-document-api/)"
fi

# ---- confirm ---------------------------------------------------------------
if [[ "$HAS_CONFIG" -eq 1 ]]; then
  read -r -p "Create release $VERSION and deploy from $CONFIG_FILE? [y/N] " ANSWER
else
  read -r -p "Create release $VERSION (build only, no deploy)? [y/N] " ANSWER
fi
[[ "$ANSWER" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# ---- create the release (triggers the pipeline) ----------------------------
# With --config, add a "Deploy Config:" line the pipeline reads to pick the target.
if [[ "$HAS_CONFIG" -eq 1 ]]; then
  gh release create "$VERSION" --repo "$REPO" --target main \
    --title "$VERSION" --notes "Deploy Config: $CONFIG_FILE"
  echo "==> Release $VERSION published — pipeline is building and deploying."
else
  gh release create "$VERSION" --repo "$REPO" --target main \
    --title "$VERSION" --generate-notes
  echo "==> Release $VERSION published — pipeline is building (build only)."
fi

echo "==> Pipeline: $ACTIONS_URL"
EOF_ZAPRELEASE
)" -- "$@"
}

# If executed directly as a script, run the function.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${ZSH_VERSION:-}" ]]; then
  zap-release "$@"
else
  command -v gh >/dev/null 2>&1 || echo "==> [WARNING] gh CLI not found; zap-release needs it."
  echo "==> Command 'zap-release' is ready!"
fi
