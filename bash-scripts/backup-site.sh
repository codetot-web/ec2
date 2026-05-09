#!/bin/bash
#
# backup-site.sh — Back up a WordPress site to S3
#
# Strategy:
#   - Database: full gzipped dump via `wp db export`, uploaded with timestamped key.
#                S3 lifecycle policy handles retention (transition to Glacier IR + expire).
#   - Uploads:  `aws s3 sync` — incremental, only changed files uploaded.
#                S3 versioning preserves history of overwrites/deletes.
#
# Auth:    EC2 instance IAM role (no AWS keys in script or env).
# Run as:  ubuntu user (no sudo needed, no root file access required).
#
# Usage:
#   /usr/local/bin/backup-site --site=NAME --bucket=BUCKET [options]
#
# See --help for full options.
#

set -euo pipefail

# ---------- Defaults ----------
SITE=""
BUCKET=""
PREFIX=""                 # default: backups/<site>
RETENTION_DAYS=7          # local .sql.gz retention (S3 lifecycle handles cloud-side)
SKIP_DB=0
SKIP_UPLOADS=0
STORAGE_CLASS="STANDARD_IA"
REGION=""
WEBAPPS_DIR="/home/ubuntu/webapps"

# ---------- Helpers ----------
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "[$(ts)] $*"; }
ok()   { echo "[$(ts)]   ✓ $*"; }
warn() { echo "[$(ts)]   ! $*"; }
err()  { echo "[$(ts)] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") --site=NAME --bucket=BUCKET [options]

Required:
  --site=NAME              Site identifier (must match an existing site dir)
  --bucket=BUCKET          S3 bucket name (must be pre-created with lifecycle policy)

Optional:
  --prefix=PATH            S3 key prefix (default: backups/<site>)
  --retention-days=N       Local .sql.gz retention in days (default: 7)
  --storage-class=CLASS    S3 storage class for new objects (default: STANDARD_IA)
                           Valid: STANDARD, STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING,
                                  GLACIER_IR
  --region=REGION          AWS region (default: from instance metadata or AWS_REGION env)
  --skip-db                Skip database backup
  --skip-uploads           Skip uploads sync
  -h, --help               Show this and exit

Examples:

  # Standard weekly backup
  /usr/local/bin/backup-site --site=masanconsumer --bucket=codetot-backups

  # DB only (e.g. mid-week incremental DB safety net)
  /usr/local/bin/backup-site --site=masanconsumer --bucket=codetot-backups --skip-uploads

  # One-off ad-hoc backup before a risky deployment
  /usr/local/bin/backup-site --site=masanconsumer --bucket=codetot-backups \\
                             --prefix=adhoc/pre-deploy-2026-05-07
EOF
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --site=*)            SITE="${arg#*=}" ;;
            --bucket=*)          BUCKET="${arg#*=}" ;;
            --prefix=*)          PREFIX="${arg#*=}" ;;
            --retention-days=*)  RETENTION_DAYS="${arg#*=}" ;;
            --storage-class=*)   STORAGE_CLASS="${arg#*=}" ;;
            --region=*)          REGION="${arg#*=}" ;;
            --skip-db)           SKIP_DB=1 ;;
            --skip-uploads)      SKIP_UPLOADS=1 ;;
            --help|-h)           usage; exit 0 ;;
            *)                   usage; err "Unknown argument: $arg" ;;
        esac
    done

    [ -n "$SITE" ]   || { usage; err "Missing --site"; }
    [ -n "$BUCKET" ] || { usage; err "Missing --bucket"; }

    [ -z "$PREFIX" ] && PREFIX="backups/${SITE}"
    PREFIX="${PREFIX%/}"   # strip trailing slash

    SITE_ROOT="$WEBAPPS_DIR/$SITE"
    PUBLIC_DIR="$SITE_ROOT/public"
    BACKUPS_DIR="$SITE_ROOT/backups"
    UPLOADS_DIR="$PUBLIC_DIR/wp-content/uploads"
}

# ---------- Pre-flight ----------
preflight() {
    [ -d "$PUBLIC_DIR" ]    || err "Site not found: $PUBLIC_DIR"
    [ -d "$BACKUPS_DIR" ]   || mkdir -p "$BACKUPS_DIR"
    command -v aws >/dev/null 2>&1 || err "aws CLI not installed"
    command -v wp  >/dev/null 2>&1 || err "wp-cli not installed"

    # Sanity-check S3 access via instance role
    local region_arg=""
    [ -n "$REGION" ] && region_arg="--region $REGION"
    if ! aws sts get-caller-identity $region_arg >/dev/null 2>&1; then
        err "AWS credentials not working (instance IAM role attached?)"
    fi
}

# ---------- Concurrency lock ----------
acquire_lock() {
    LOCKFILE="/tmp/wp-backup-${SITE}.lock"
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        err "Another backup for '$SITE' is already running (lock: $LOCKFILE)"
    fi
}

# ---------- Steps ----------

step_db_backup() {
    if [ "$SKIP_DB" -eq 1 ]; then
        warn "--skip-db set, skipping database backup"
        return
    fi

    local stamp
    stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    local dump_name="db-${stamp}.sql.gz"
    local local_path="$BACKUPS_DIR/$dump_name"
    local s3_key="$PREFIX/db/$dump_name"

    log "Dumping database for $SITE → $local_path"
    cd "$PUBLIC_DIR"

    # --add-drop-table makes the dump self-contained for restore.
    # Pipe through gzip --best for max compression (DB dumps compress very well).
    if ! wp db export - --add-drop-table --default-character-set=utf8mb4 \
            2>/dev/null | gzip --best > "$local_path"; then
        rm -f "$local_path"
        err "wp db export failed"
    fi

    local size
    size=$(du -h "$local_path" | cut -f1)
    ok "Dump complete ($size)"

    log "Uploading to s3://$BUCKET/$s3_key"
    local region_arg=""
    [ -n "$REGION" ] && region_arg="--region $REGION"

    aws s3 cp "$local_path" "s3://$BUCKET/$s3_key" \
        --storage-class "$STORAGE_CLASS" \
        --metadata "site=$SITE,backup-time=$stamp,size=$size" \
        --only-show-errors \
        $region_arg
    ok "DB uploaded"
}

step_uploads_sync() {
    if [ "$SKIP_UPLOADS" -eq 1 ]; then
        warn "--skip-uploads set, skipping uploads sync"
        return
    fi
    if [ ! -d "$UPLOADS_DIR" ]; then
        warn "$UPLOADS_DIR doesn't exist, skipping uploads sync"
        return
    fi

    local s3_path="s3://$BUCKET/$PREFIX/uploads/"
    log "Syncing uploads incrementally → $s3_path"

    local region_arg=""
    [ -n "$REGION" ] && region_arg="--region $REGION"

    # `aws s3 sync` is the rsync-equivalent for S3:
    #   - Compares size + mtime, uploads only changed/new files
    #   - --size-only would be faster but misses content edits with same size
    #   - --delete is intentionally OFF: deleted local files stay in S3 (versioning
    #     + lifecycle policy handles retention)
    aws s3 sync "$UPLOADS_DIR/" "$s3_path" \
        --storage-class "$STORAGE_CLASS" \
        --exclude "*.tmp" \
        --exclude ".DS_Store" \
        --exclude "Thumbs.db" \
        --only-show-errors \
        $region_arg
    ok "Uploads synced"
}

step_local_cleanup() {
    log "Cleaning local dumps older than $RETENTION_DAYS days"
    local count
    count=$(find "$BACKUPS_DIR" -name 'db-*.sql.gz' -mtime "+$RETENTION_DAYS" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        find "$BACKUPS_DIR" -name 'db-*.sql.gz' -mtime "+$RETENTION_DAYS" -delete
        ok "Removed $count old dump(s)"
    else
        ok "Nothing to clean"
    fi
}

step_summary() {
    log "Backup complete for $SITE"

    local region_arg=""
    [ -n "$REGION" ] && region_arg="--region $REGION"

    # Show the most recent objects in S3 for verification
    log "Latest DB backup in S3:"
    aws s3 ls "s3://$BUCKET/$PREFIX/db/" $region_arg \
        | sort \
        | tail -3 \
        | awk '{printf "    %s  %10d  %s\n", $1" "$2, $3, $4}'

    if [ "$SKIP_UPLOADS" -ne 1 ]; then
        log "Uploads location:"
        echo "    s3://$BUCKET/$PREFIX/uploads/"
    fi
}

# ---------- Main ----------
parse_args "$@"
preflight
acquire_lock
step_db_backup
step_uploads_sync
step_local_cleanup
step_summary
