#!/bin/bash
#
# migrate-site.sh — Move a WordPress site from a staging VPS to production EC2 + RDS
#
# Reads all config from .env (see .env.sample). Run from the repo root:
#
#   bash tools/migrate-site.sh [--env=path/to/.env] [--skip-provision]
#                               [--skip-db] [--skip-uploads] [--dry-run]
#
# What it does:
#   1. Provisions the site on EC2 via create-site.sh (dirs, vhost, FPM, RDS DB + wp-config)
#   2. Exports DB from staging MySQL and imports it into RDS via EC2
#   3. Search-replaces staging domain → prod domain in the DB
#   4. Rsyncs wp-content/uploads/ from staging → EC2
#   5. Writes .htaccess, flushes rewrites, fixes permissions
#
# Safe to re-run: create-site.sh is idempotent; rsync is incremental.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- Defaults ----------
ENV_FILE="$REPO_ROOT/.env"
SKIP_PROVISION=0
SKIP_DB=0
SKIP_UPLOADS=0
DRY_RUN=0

# ---------- Helpers ----------
log()  { echo -e "\n\033[1;36m==>\033[0m $*"; }
ok()   { echo -e "    \033[1;32m✓\033[0m $*"; }
warn() { echo -e "    \033[1;33m!\033[0m $*"; }
err()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }
dry()  { [ "$DRY_RUN" -eq 1 ] && echo "    [dry-run] $*" || true; }

for arg in "$@"; do
    case "$arg" in
        --env=*)           ENV_FILE="${arg#*=}" ;;
        --skip-provision)  SKIP_PROVISION=1 ;;
        --skip-db)         SKIP_DB=1 ;;
        --skip-uploads)    SKIP_UPLOADS=1 ;;
        --dry-run)         DRY_RUN=1 ;;
        --help|-h)
            sed -n '3,12p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Unknown flag: $arg" ;;
    esac
done

# ---------- Load config ----------
[ -f "$ENV_FILE" ] || err ".env not found: $ENV_FILE\n  Copy .env.sample → .env and fill in values."
# shellcheck disable=SC1090
source "$ENV_FILE"

# Required vars
for var in STAGING_SSH STAGING_DOMAIN STAGING_WP_PATH \
           EC2_SSH RDS_HOST RDS_MASTER_USER RDS_MASTER_PASS \
           SITE PROD_DOMAIN; do
    [ -n "${!var:-}" ] || err "Missing required .env variable: $var"
done

# Optional with defaults
GIT_REPO="${GIT_REPO:-}"
GIT_BRANCH="${GIT_BRANCH:-master}"
TABLE_PREFIX="${TABLE_PREFIX:-wp_}"
PHP_VERSION="${PHP_VERSION:-8.3}"
MEMORY_LIMIT="${MEMORY_LIMIT:-512M}"
UPLOAD_MAX="${UPLOAD_MAX:-64M}"
MAX_CHILDREN="${MAX_CHILDREN:-20}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
STAGING_SSH_PASS="${STAGING_SSH_PASS:-}"

# SSH helpers — staging may need sshpass; EC2 uses key-based auth
EC2_KEY_FLAG=""
[ -n "${EC2_SSH_KEY:-}" ] && EC2_KEY_FLAG="-i $EC2_SSH_KEY"

staging_ssh() {
    if [ -n "$STAGING_SSH_PASS" ]; then
        sshpass -p "$STAGING_SSH_PASS" ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
            "$STAGING_SSH" "$@"
    else
        ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 "$STAGING_SSH" "$@"
    fi
}

ec2_ssh() {
    # shellcheck disable=SC2086
    ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 $EC2_KEY_FLAG "$EC2_SSH" "$@"
}

staging_scp_to_ec2() {
    local src="$1" dst="$2"
    staging_ssh "scp -o StrictHostKeyChecking=no $EC2_KEY_FLAG '$src' '${EC2_SSH}:${dst}'"
}

EC2_SITE_ROOT="/home/ubuntu/webapps/$SITE"
EC2_PUBLIC_DIR="$EC2_SITE_ROOT/public"
DUMP_FILE="/tmp/${SITE}-migrate-$(date +%Y%m%d%H%M).sql"

# ---------- Step 0 — Pre-flight ----------
step_preflight() {
    log "Pre-flight checks"

    [ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN mode — no changes will be made"

    # Reachability
    staging_ssh "echo staging-ok" >/dev/null || err "Cannot reach staging: $STAGING_SSH"
    ok "Staging reachable: $STAGING_SSH"

    ec2_ssh "echo ec2-ok" >/dev/null || err "Cannot reach EC2: $EC2_SSH"
    ok "EC2 reachable: $EC2_SSH"

    # Staging WP path
    staging_ssh "[ -f '${STAGING_WP_PATH}/wp-config.php' ]" \
        || err "wp-config.php not found at $STAGING_WP_PATH on staging"
    ok "WordPress found at $STAGING_WP_PATH"

    # EC2 bootstrap
    ec2_ssh "[ -d /home/ubuntu/webapps ]" \
        || err "EC2 not bootstrapped — run ct-bootstrap first"
    ok "EC2 bootstrapped"

    # Authorize staging → EC2 SSH (needed for direct rsync + scp)
    local staging_pubkey
    staging_pubkey=$(staging_ssh "cat /home/ubuntu/.ssh/id_ed25519.pub 2>/dev/null || \
        ssh-keygen -t ed25519 -f /home/ubuntu/.ssh/id_ed25519 -N '' -C 'ubuntu@staging-migrate' \
        >/dev/null 2>&1 && cat /home/ubuntu/.ssh/id_ed25519.pub")
    ec2_ssh "grep -qF '${staging_pubkey}' ~/.ssh/authorized_keys 2>/dev/null || \
        echo '${staging_pubkey}' >> ~/.ssh/authorized_keys"
    ok "Staging → EC2 SSH trust established"
}

# ---------- Step 1 — Provision on EC2 ----------
step_provision() {
    if [ "$SKIP_PROVISION" -eq 1 ]; then
        warn "--skip-provision: skipping EC2 site setup"
        return
    fi

    log "Provisioning site '$SITE' on EC2"
    [ "$DRY_RUN" -eq 1 ] && { dry "Would run create-site.sh on EC2"; return; }

    # Upload create-site.sh
    scp -o StrictHostKeyChecking=no $EC2_KEY_FLAG \
        "$REPO_ROOT/bash-scripts/create-site.sh" "${EC2_SSH}:/tmp/create-site.sh"

    # Build args
    local args="--site=$SITE --domain=$PROD_DOMAIN"
    args="$args --rds-host=$RDS_HOST --rds-master-user=$RDS_MASTER_USER"
    args="$args --table-prefix=$TABLE_PREFIX --php-version=$PHP_VERSION"
    args="$args --memory-limit=$MEMORY_LIMIT --upload-max=$UPLOAD_MAX"
    args="$args --max-children=$MAX_CHILDREN --vpc-cidr=$VPC_CIDR"
    [ -n "$GIT_REPO" ] && args="$args --git-repo=$GIT_REPO --git-branch=$GIT_BRANCH"
    args="$args --force"   # safe re-run: overwrites config, not DB data

    ec2_ssh "sudo RDS_MASTER_PASS='${RDS_MASTER_PASS}' bash /tmp/create-site.sh $args"
    ok "Site provisioned on EC2"
}

# ---------- Step 2 — Sync database ----------
step_sync_db() {
    if [ "$SKIP_DB" -eq 1 ]; then
        warn "--skip-db: skipping database sync"
        return
    fi

    log "Exporting DB from staging"
    [ "$DRY_RUN" -eq 1 ] && { dry "Would export $STAGING_WP_PATH DB and import to RDS"; return; }

    staging_ssh "sudo -u ubuntu wp db export $DUMP_FILE \
        --path=$STAGING_WP_PATH --allow-root 2>&1 | tail -2"
    ok "DB exported to $DUMP_FILE on staging"

    log "Transferring DB dump staging → EC2"
    staging_scp_to_ec2 "$DUMP_FILE" "$DUMP_FILE"
    ok "DB dump transferred to EC2"

    log "Importing DB into RDS"
    ec2_ssh "cd $EC2_PUBLIC_DIR && sudo -u ubuntu wp db import $DUMP_FILE 2>&1 | tail -2"
    ok "DB imported into RDS"

    log "Cleaning up dump files"
    staging_ssh "rm -f $DUMP_FILE"
    ec2_ssh "rm -f $DUMP_FILE"
    ok "Dump files removed"

    # Search-replace only when domains differ
    if [ "$STAGING_DOMAIN" != "$PROD_DOMAIN" ]; then
        log "Replacing $STAGING_DOMAIN → $PROD_DOMAIN"
        ec2_ssh "cd $EC2_PUBLIC_DIR && \
            sudo -u ubuntu wp search-replace 'https://${STAGING_DOMAIN}' 'https://${PROD_DOMAIN}' \
                --all-tables --skip-columns=guid --report-changed-only 2>&1 \
            | grep -v '^WordPress database error' | tail -5"
        ok "URL search-replace complete"
    else
        ok "Staging and prod domains match — no search-replace needed"
    fi
}

# ---------- Step 3 — Sync uploads ----------
step_sync_uploads() {
    if [ "$SKIP_UPLOADS" -eq 1 ]; then
        warn "--skip-uploads: skipping uploads sync"
        return
    fi

    log "Rsyncing uploads staging → EC2 (incremental)"
    [ "$DRY_RUN" -eq 1 ] && { dry "Would rsync $STAGING_WP_PATH/wp-content/uploads/ → EC2"; return; }

    local src="${STAGING_WP_PATH}/wp-content/uploads/"
    local dst="${EC2_PUBLIC_DIR}/wp-content/uploads/"
    local ec2_host="${EC2_SSH#*@}"
    local ec2_user="${EC2_SSH%%@*}"

    staging_ssh "sudo -u ubuntu rsync -az \
        -e 'ssh -o StrictHostKeyChecking=no ${EC2_KEY_FLAG}' \
        '$src' '${ec2_user}@${ec2_host}:${dst}'"
    ok "Uploads synced"
}

# ---------- Step 4 — Finalise ----------
step_finalise() {
    log "Writing .htaccess + flushing rewrites + fixing permissions"
    [ "$DRY_RUN" -eq 1 ] && { dry "Would finalise site on EC2"; return; }

    ec2_ssh "bash -s" <<REMOTE
set -euo pipefail
HTACCESS="$EC2_PUBLIC_DIR/.htaccess"
if [ ! -f "\$HTACCESS" ]; then
    sudo -u ubuntu tee "\$HTACCESS" >/dev/null <<'HTACCESS_EOF'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php\$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTACCESS_EOF
    echo "    .htaccess written"
fi

cd $EC2_PUBLIC_DIR
sudo -u ubuntu wp rewrite flush 2>/dev/null || true
sudo -u ubuntu wp cache flush 2>/dev/null || true
echo "    rewrites + cache flushed"

# Inline permissions (ct-fix-perm if available, else fallback)
if command -v ct-fix-perm >/dev/null 2>&1; then
    sudo ct-fix-perm --site=$SITE
else
    chown -R ubuntu:www-data $EC2_SITE_ROOT
    find $EC2_SITE_ROOT -path "*/.git" -prune -o -type d -exec chmod 2775 {} +
    find $EC2_SITE_ROOT -path "*/.git" -prune -o -type f -exec chmod 0664 {} +
    [ -f $EC2_PUBLIC_DIR/wp-config.php ] && chmod 640 $EC2_PUBLIC_DIR/wp-config.php
    [ -f $EC2_SITE_ROOT/.credentials ]   && chmod 600 $EC2_SITE_ROOT/.credentials
    echo "    permissions fixed"
fi
REMOTE
    ok "Site finalised"
}

# ---------- Step 5 — Smoke test ----------
step_smoke_test() {
    log "Smoke test"
    local url
    url=$(ec2_ssh "cd $EC2_PUBLIC_DIR && sudo -u ubuntu wp option get siteurl 2>/dev/null")
    ok "siteurl: $url"

    local post
    post=$(ec2_ssh "cd $EC2_PUBLIC_DIR && \
        sudo -u ubuntu wp post list --post_type=post --posts_per_page=1 \
        --fields=post_title --format=csv 2>/dev/null | tail -1")
    ok "latest post: $post"

    local upload_size
    upload_size=$(ec2_ssh "du -sh $EC2_PUBLIC_DIR/wp-content/uploads/ 2>/dev/null | cut -f1")
    ok "uploads: $upload_size"
}

# ---------- Summary ----------
step_summary() {
    echo ""
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │  Migration complete: $SITE"
    echo "  │"
    echo "  │  Site root:   $EC2_SITE_ROOT"
    echo "  │  Domain:      https://$PROD_DOMAIN"
    echo "  │  RDS host:    $RDS_HOST"
    echo "  │  DB/user:     $SITE  (REQUIRE SSL)"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
    echo "  Next steps:"
    echo "  1. Verify https://$PROD_DOMAIN in a browser"
    echo "  2. Update CloudFlare DNS: $PROD_DOMAIN → EC2/ALB"
    echo "  3. Add WP-Cron to crontab on EC2:"
    echo "     */5 * * * * cd $EC2_PUBLIC_DIR && /usr/local/bin/wp cron event run --due-now >/dev/null 2>&1"
    echo "  4. Set up backup: ct-backup --site=$SITE --bucket=<your-bucket>"
    echo ""
}

# ---------- Main ----------
step_preflight
step_provision
step_sync_db
step_sync_uploads
step_finalise
step_smoke_test
step_summary
