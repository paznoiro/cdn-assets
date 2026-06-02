#!/bin/sh
pulumi-list() { 
    echo "npm run pulumi:list";
    npm run pulumi:list;
}
pulumi-cleanup() {
    pulumi-list
    STACK="${1:-$(pulumi stack --show-name --cwd pulumi/)}"
    echo "npm run pulumi:cleanup -- --stack $STACK"
    npm run pulumi:cleanup -- --stack "$STACK"
}
pulumi-setup() { 
    echo "npm run pulumi:setup -- --properties ../$1"
    npm run pulumi:setup -- --properties "../$1"; 
}
pulumi-trash() {
    # Use argument if provided, otherwise use current Pulumi stack
    local SEARCH_NAME="${1:-$(pulumi stack --show-name  --cwd pulumi 2>/dev/null)}"

    if [ -z "$SEARCH_NAME" ]; then
        echo "❌ No stack provided and no active Pulumi stack found"
        echo "Usage: pulumi-trash <stackname>"
        return 1
    fi

    local SEARCH_DIR="./pulumi"

    # Check if pulumi directory exists
    if [ ! -d "$SEARCH_DIR" ]; then
        echo "Error: Directory '$SEARCH_DIR' does not exist"
        return 1
    fi

    echo "Searching for files and folders named: $SEARCH_NAME"
    echo "Search directory: $SEARCH_DIR"
    echo "================================================"

    # Find all matching files and directories
    local MATCHES
    MATCHES=$(find "$SEARCH_DIR" -name "$SEARCH_NAME" 2>/dev/null)

    if [ -z "$MATCHES" ]; then
        echo "No matches found for '$SEARCH_NAME'"
        return 0
    fi

    # Display matches
    echo "Found the following matches:"
    echo "$MATCHES"
    echo ""

    # Count matches
    local COUNT
    COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
    echo "Total matches: $COUNT"
    echo ""

    # Confirmation
    printf "Do you want to delete all these files/folders? (yes/no): "
    read CONFIRM

    if [ "$CONFIRM" = "yes" ]; then
        echo "Deleting..."
        echo "$MATCHES" | while read -r item; do
            if [ -e "$item" ]; then
                rm -rf "$item"
                echo "Deleted: $item"
            fi
        done
        echo "Deletion complete!"
    else
        echo "Deletion cancelled."
    fi
}
zapdeploy() {
  if [ $# -ne 2 ]; then
    echo "Usage: zapdeploy <service> <env> , Example: zapdeploy production deploy"
    return 1
  fi

  local config="$1-api/deploy/$2.conf"
  if [ ! -f "$config" ]; then
    echo "❌ Config file not found: $config"
    return 1
  fi
  echo "🚀 Running deploy with config: $config"
  echo "../deploy-scripts/gcloud-deploy-jib.sh --config $config"

  ./deploy-scripts/gcloud-deploy-jib.sh --config "$config"
}
dbmigrate() {
  if [ $# -lt 3 ]; then
    echo "Usage: dbmigrate <env> <service> <tenant> [schema]"
    return 1
  fi

  local env=$1
  local service=$2
  local tenant=$3
  local schema=${4:-$service}   # default schema = service

  ./deploy-scripts/migrate.sh \
    --conf ${service}-api/deploy/${env}.conf \
    --service ${service}-api \
    --mode single-schema \
    --schema-name ${schema} \
    --tenant ${tenant} \
    --with-seed
}

export-d1() {
    if [ -z "$1" ]; then
        echo "Usage: export-d1 <stackname>"
        return 1
    fi
    local full_name=$1
    local config_path="pulumi/instances/$full_name/wrangler.toml"
    
    if [ ! -f "$config_path" ]; then
        echo "Error: Configuration file not found: $config_path"
        return 1
    fi

    local db_name
    db_name=$(awk -F'"' '/^\[\[d1_databases\]\]/{found=1} found && /database_name/{print $2; exit}' "$config_path")

    if [ -z "$db_name" ]; then
        echo "Error: Could not find database_name in $config_path"
        return 1
    fi

    echo "Exporting data for: $full_name, Database: $db_name"
    
    npx wrangler d1 export "$db_name" \
        --remote \
        --output="./data-${full_name}.sql" \
        --no-schema \
        --config "$config_path"
    
    if [ $? -eq 0 ]; then
        echo "Export completed: ./data-${full_name}.sql"
    else
        echo "Export failed"
        return 1
    fi
}

import-d1() {
    if [ -z "$1" ]; then
        echo "Usage: import-d1 <stackname> [sql_file]"
        return 1
    fi
    local full_name=$1
    local config_path="pulumi/instances/$full_name/wrangler.toml"
    local sql_file="${2:-./data-${full_name}.sql}"
    
    if [ ! -f "$config_path" ]; then
        echo "Error: Configuration file not found: $config_path"
        return 1
    fi
    if [ ! -f "$sql_file" ]; then
        echo "Error: SQL file not found: $sql_file"
        return 1
    fi

    local db_name
    db_name=$(awk -F'"' '/^\[\[d1_databases\]\]/{found=1} found && /database_name/{print $2; exit}' "$config_path")

    if [ -z "$db_name" ]; then
        echo "Error: Could not find database_name in $config_path"
        return 1
    fi
    
    echo "SQL: $sql_file, Database: $db_name, Config: $config_path"
    
    printf "This will overwrite existing data. Continue? (y/N) "
    read response
    case "$response" in
        [Yy]* ) ;;
        * ) echo "Aborted"; return 1;;
    esac
    
    npx wrangler d1 execute "$db_name" \
        --remote \
        --file="$sql_file" \
        --config "$config_path"
    
    if [ $? -eq 0 ]; then
        echo "Import completed successfully"
    else
        echo "Import failed"
        return 1
    fi
}

gitacp() {
    git add -A && git commit -m "$*" && git push && git --no-pager diff --name-status HEAD~1
}
gitForce(){
    git add .
    git commit -m "Force sync local to remote"
    git push --force origin main
}
gitpulumisub () {
  SUBMODULE_URL="https://github.com/azoth-tech/pulumi-cloudflare.git"
  SUBMODULE_PATH="pulumi-cloudflare"
  SUBMODULE_BRANCH="main"

  # Must be inside a git repo
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "Not inside a git repository"
    return 1
  }

  if [ ! -d "$SUBMODULE_PATH/.git" ]; then
    echo "Adding submodule $SUBMODULE_PATH"

    git submodule add -b "$SUBMODULE_BRANCH" "$SUBMODULE_URL" "$SUBMODULE_PATH"
    git add .gitmodules "$SUBMODULE_PATH"
    git commit -m "Add pulumi-cloudflare submodule (main branch)"

  else
    echo "Submodule exists — force updating from remote"

    cd "$SUBMODULE_PATH" || return 1
    git fetch origin
    git checkout "$SUBMODULE_BRANCH"
    git reset --hard "origin/$SUBMODULE_BRANCH"
    cd - >/dev/null || return 1

    git add "$SUBMODULE_PATH"
    git commit -m "Force update pulumi-cloudflare submodule from origin/main"
  fi

  git submodule status
}
gitinit () {
  if [ -z "$1" ]; then
    echo "Usage: gitinit <repo-url>"
    return 1
  fi

  if [ -d .git ]; then
    echo "Git repository already initialized"
    return 1
  fi

  git init
  git branch -M main
  git remote add origin "$1"

  # Try to commit if there are files
  git add .
  if git diff --cached --quiet; then
    echo "Nothing to commit yet"
  else
    git commit -m "Initial commit"
  fi

  # Try to push (won't crash if remote fails)
  git push -u origin main || echo "Push failed (maybe remote is empty or no permissions)"

  git status
}
claude_lmstudio(){
  export ANTHROPIC_BASE_URL="http://localhost:1234"
  export ANTHROPIC_AUTH_TOKEN="lmstudio"
  echo "Anthropic env enabled"
}
claude_zenmux(){
  export ANTHROPIC_BASE_URL="https://zenmux.ai/api/anthropic"
  export ANTHROPIC_AUTH_TOKEN=${ZENMUX_API_KEY}
  echo "Zenmux Anthropic env enabled"
}

claude_clear(){
  unset ANTHROPIC_BASE_URL
  unset ANTHROPIC_AUTH_TOKEN
  echo "Anthropic env disabled"
}

cf_setup(){
    unset CLOUDFLARE_ACCOUNT_ID
    unset CLOUDFLARE_API_TOKEN
    export CLOUDFLARE_ACCOUNT_ID=$(doppler secrets get CLOUDFLARE_ACCOUNT_ID \
      --project cloudflare \
      --config $1 \
      --plain)

    export CLOUDFLARE_API_TOKEN=$(doppler secrets get CLOUDFLARE_API_TOKEN \
      --project cloudflare \
      --config $1 \
      --plain)
}

gcloud_zap_setup(){
    unset EMBED_API_KEY
    unset LLM_API_KEY
    unset POSTGRES_DB_PASS
    unset QDRANT_API_KEY
    export EMBED_API_KEY=$(doppler secrets get EMBED_API_KEY \
      --project gcloud-zap \
      --config $1 \
      --plain)

    export LLM_API_KEY=$(doppler secrets get LLM_API_KEY \
      --project gcloud-zap \
      --config $1 \
      --plain)

    export POSTGRES_DB_PASS=$(doppler secrets get POSTGRES_DB_PASS \
      --project gcloud-zap \
      --config $1 \
      --plain)

    export QDRANT_API_KEY=$(doppler secrets get QDRANT_API_KEY \
      --project gcloud-zap \
      --config $1 \
      --plain)

}
filebase-s3() {
    aws configure set aws_access_key_id "$FILEBASE_ACCESS_KEY"
    aws configure set aws_secret_access_key "$FILEBASE_SECRET_KEY"
    aws configure set default.region "us-east-1"

    export AWS_ENDPOINT_URL="https://s3.filebase.com"
    alias aws-fb='aws --endpoint https://s3.filebase.io'

    echo "Filebase S3 configured"
}
alias plist=pulumi-list
alias pclean=pulumi-cleanup
