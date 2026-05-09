#!/bin/bash
#
# create-site.sh — Scaffold a new WordPress site under /home/ubuntu/webapps/<site>/
#
# Creates:
#   - Directory structure (public, logs, backups, tmp)
#   - Optional git clone of the WordPress repo into public/
#   - RDS database + matching-name user (db name == db user)
#   - Apache vhost  → /etc/apache2/sites-available/<site>.conf
#   - PHP-FPM pool  → /etc/php/<ver>/fpm/pool.d/<site>.conf
#   - wp-config.php with proxy fix + RDS SSL + URLs (via wp config create)
#   - .credentials file (mode 600, ubuntu only) recording the generated DB password
#   - Initial permissions (ubuntu:www-data 2775/0664, .git locked to ubuntu)
#
# Prerequisite: bootstrap-ec2-wordpress.sh has been run on this host.
#
# Usage:
#   sudo bash create-site.sh --site=NAME --domain=DOMAIN [options]
#
# See --help for all flags.
#

set -euo pipefail

# ---------- Defaults ----------
SITE=""
DOMAIN=""
ALIAS=""
GIT_REPO=""
GIT_BRANCH="main"
PHP_VERSION="8.3"
MEMORY_LIMIT="512M"
UPLOAD_MAX="64M"
MAX_CHILDREN="20"
VPC_CIDR="10.0.0.0/16"
RDS_HOST=""
RDS_MASTER_USER="admin"
RDS_MASTER_PASS="${RDS_MASTER_PASS:-}"
DB_PASS=""
WEBAPPS_DIR="/home/ubuntu/webapps"
RDS_CA_PATH="/etc/ssl/certs/rds-global-bundle.pem"
SKIP_DB=0
SKIP_CLONE=0
LOCAL_DB=0   # skip RDS SSL enforcement (for local MySQL dev/test hosts)
FORCE=0

# ---------- Helpers ----------
log()  { echo -e "\n\033[1;36m==>\033[0m $*"; }
ok()   { echo -e "    \033[1;32m✓\033[0m $*"; }
warn() { echo -e "    \033[1;33m!\033[0m $*"; }
err()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo bash $(basename "$0") --site=NAME --domain=DOMAIN [options]

Required:
  --site=NAME              Site identifier — used for path, vhost name, FPM pool,
                           DB name AND DB user (these are intentionally identical).
                           Allowed chars: a-z 0-9 _ -    Max length: 32
  --domain=DOMAIN          Primary domain (e.g. acmeshop.example.com)

Optional layout / Apache:
  --alias=LIST             Comma-separated ServerAlias domains
                           (default: www.<domain>)
  --vpc-cidr=CIDR          RemoteIPInternalProxy for ALB (default: 10.0.0.0/16)

Code source:
  --git-repo=URL           Clone WordPress project repo into public/
                           (use ssh alias, e.g. github.com-<site>:org/repo.git)
  --git-branch=NAME        Branch to clone (default: main)
  --skip-clone             Skip cloning even if --git-repo is set

PHP-FPM tuning:
  --php-version=VER        PHP version (default: 8.3)
  --memory-limit=VAL       PHP memory_limit (default: 512M)
  --upload-max=VAL         upload_max_filesize + post_max_size (default: 64M)
  --max-children=N         pm.max_children (default: 20)

RDS / database (db name == db user, both equal to --site):
  --rds-host=HOST          RDS endpoint (omit to skip DB + wp-config setup entirely)
  --rds-master-user=USER   RDS admin user (default: admin)
  --rds-master-pass=PASS   RDS admin pass — or set env RDS_MASTER_PASS
  --db-pass=PASS           App user password (auto-generated if omitted)
  --skip-db                Skip DB creation even if --rds-host is given
  --local-db               Use local MySQL without SSL (dev/test only — not for RDS)

Other:
  --force                  Overwrite existing files (NOT existing databases)
  -h, --help               Show this and exit

Examples:

  # Full setup with Git repo + RDS
  sudo RDS_MASTER_PASS='masterPass' bash $(basename "$0") \\
       --site=acmeshop --domain=acmeshop.example.com \\
       --git-repo=git@github.com-acmeshop:your-org-clients/acmeshop.git \\
       --rds-host=mydb.abc123.ap-southeast-1.rds.amazonaws.com

  # Empty site (no repo, no DB) — just scaffold dirs/vhost/pool
  sudo bash $(basename "$0") --site=staging --domain=staging.example.com

  # Custom PHP tuning for a heavier site
  sudo RDS_MASTER_PASS='masterPass' bash $(basename "$0") \\
       --site=bigshop --domain=bigshop.com \\
       --memory-limit=1024M --upload-max=128M --max-children=40 \\
       --rds-host=mydb.abc123.ap-southeast-1.rds.amazonaws.com
EOF
}

require_root() {
    [ "$EUID" -eq 0 ] || err "Run as root (use sudo)"
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --site=*)            SITE="${arg#*=}" ;;
            --domain=*)          DOMAIN="${arg#*=}" ;;
            --alias=*)           ALIAS="${arg#*=}" ;;
            --git-repo=*)        GIT_REPO="${arg#*=}" ;;
            --git-branch=*)      GIT_BRANCH="${arg#*=}" ;;
            --php-version=*)     PHP_VERSION="${arg#*=}" ;;
            --memory-limit=*)    MEMORY_LIMIT="${arg#*=}" ;;
            --upload-max=*)      UPLOAD_MAX="${arg#*=}" ;;
            --max-children=*)    MAX_CHILDREN="${arg#*=}" ;;
            --vpc-cidr=*)        VPC_CIDR="${arg#*=}" ;;
            --rds-host=*)        RDS_HOST="${arg#*=}" ;;
            --rds-master-user=*) RDS_MASTER_USER="${arg#*=}" ;;
            --rds-master-pass=*) RDS_MASTER_PASS="${arg#*=}" ;;
            --db-pass=*)         DB_PASS="${arg#*=}" ;;
            --skip-db)           SKIP_DB=1 ;;
            --local-db)          LOCAL_DB=1 ;;
            --skip-clone)        SKIP_CLONE=1 ;;
            --force)             FORCE=1 ;;
            --help|-h)           usage; exit 0 ;;
            *)                   usage; err "Unknown argument: $arg" ;;
        esac
    done

    [ -n "$SITE" ]   || { usage; err "Missing --site"; }
    [ -n "$DOMAIN" ] || { usage; err "Missing --domain"; }

    # Site name validation: a-z 0-9 _ -
    [[ "$SITE" =~ ^[a-z0-9_-]+$ ]] || err "Invalid --site (must match [a-z0-9_-]): $SITE"
    [ "${#SITE}" -le 32 ] || err "Site name too long: ${#SITE} chars (MySQL user max is 32)"

    # Default alias = www.<domain>
    [ -z "$ALIAS" ] && ALIAS="www.${DOMAIN}"

    # Generate DB password if not provided (32 alphanumeric chars)
    if [ -z "$DB_PASS" ]; then
        DB_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    fi

    # Computed paths
    SITE_ROOT="$WEBAPPS_DIR/$SITE"
    PUBLIC_DIR="$SITE_ROOT/public"
}

# ---------- Pre-flight ----------
preflight() {
    [ -d "$WEBAPPS_DIR" ] || err "$WEBAPPS_DIR doesn't exist — run bootstrap-ec2-wordpress.sh first"
    command -v wp        >/dev/null 2>&1 || err "wp-cli not found"
    command -v apache2   >/dev/null 2>&1 || err "Apache not installed"
    command -v mysql     >/dev/null 2>&1 || err "mysql client not installed"
    [ -d "/etc/php/${PHP_VERSION}/fpm/pool.d" ] || \
        err "PHP ${PHP_VERSION} FPM not installed. Install it with: sudo ct-install-php ${PHP_VERSION}"

    if [ -d "$SITE_ROOT" ] && [ "$FORCE" -ne 1 ]; then
        err "Site directory exists: $SITE_ROOT (use --force to overwrite config files)"
    fi
    if [ -f "/etc/apache2/sites-available/${SITE}.conf" ] && [ "$FORCE" -ne 1 ]; then
        err "Apache vhost exists: ${SITE}.conf (use --force)"
    fi
    if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/${SITE}.conf" ] && [ "$FORCE" -ne 1 ]; then
        err "FPM pool exists: ${SITE}.conf (use --force)"
    fi
    if [ -n "$RDS_HOST" ] && [ "$SKIP_DB" -ne 1 ] && [ -z "$RDS_MASTER_PASS" ]; then
        err "RDS_MASTER_PASS not set (env var or --rds-master-pass required for DB setup)"
    fi
}

# ---------- Steps ----------

step_create_dirs() {
    log "Creating directory structure"
    mkdir -p "$SITE_ROOT"/{public,logs,backups,tmp}
    chown -R ubuntu:www-data "$SITE_ROOT"
    chmod 2775 "$SITE_ROOT" "$SITE_ROOT"/{public,logs,backups,tmp}
    ok "$SITE_ROOT created"
}

step_clone_repo() {
    if [ -z "$GIT_REPO" ]; then
        warn "No --git-repo, skipping clone"
        return
    fi
    if [ "$SKIP_CLONE" -eq 1 ]; then
        warn "--skip-clone set, skipping clone"
        return
    fi

    log "Cloning $GIT_REPO (branch: $GIT_BRANCH)"

    # Git clone needs an empty target
    if [ -n "$(ls -A "$PUBLIC_DIR" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
        err "$PUBLIC_DIR is not empty (use --force)"
    fi
    rm -rf "$PUBLIC_DIR"

    sudo -u ubuntu git clone --branch "$GIT_BRANCH" "$GIT_REPO" "$PUBLIC_DIR"
    ok "Cloned to $PUBLIC_DIR"
}

step_create_database() {
    if [ -z "$RDS_HOST" ]; then
        warn "No --rds-host, skipping DB setup"
        return
    fi
    if [ "$SKIP_DB" -eq 1 ]; then
        warn "--skip-db set, skipping DB setup"
        return
    fi

    log "Creating RDS database '$SITE' + user '$SITE' (matching names)"

    # Use --defaults-extra-file so the password never appears in process list
    local cnf
    cnf=$(mktemp)
    chmod 600 "$cnf"

    if [ "$LOCAL_DB" -eq 1 ]; then
        # Local MySQL (dev/test): no SSL enforcement
        cat > "$cnf" <<EOF
[client]
host=$RDS_HOST
user=$RDS_MASTER_USER
password=$RDS_MASTER_PASS
EOF
        mysql --defaults-extra-file="$cnf" <<SQL
CREATE DATABASE IF NOT EXISTS \`$SITE\`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$SITE'@'%' IDENTIFIED BY '$DB_PASS';
ALTER USER '$SITE'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$SITE\`.* TO '$SITE'@'%';
FLUSH PRIVILEGES;
SQL
        rm -f "$cnf"
        warn "Local DB mode — REQUIRE SSL skipped (not for production RDS)"
        ok "Database '$SITE' + user '$SITE' ready"
    else
        # RDS: enforce SSL on user + connection
        cat > "$cnf" <<EOF
[client]
host=$RDS_HOST
user=$RDS_MASTER_USER
password=$RDS_MASTER_PASS
ssl-ca=$RDS_CA_PATH
EOF
        mysql --defaults-extra-file="$cnf" <<SQL
CREATE DATABASE IF NOT EXISTS \`$SITE\`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$SITE'@'%' IDENTIFIED BY '$DB_PASS' REQUIRE SSL;
ALTER USER '$SITE'@'%' IDENTIFIED BY '$DB_PASS' REQUIRE SSL;
GRANT ALL PRIVILEGES ON \`$SITE\`.* TO '$SITE'@'%';
FLUSH PRIVILEGES;
SQL
        rm -f "$cnf"
        ok "Database '$SITE' + user '$SITE' ready (REQUIRE SSL)"
    fi

    # Verify the app user can actually connect
    log "Verifying app user connection"
    cnf=$(mktemp)
    chmod 600 "$cnf"
    cat > "$cnf" <<EOF
[client]
host=$RDS_HOST
user=$SITE
password=$DB_PASS
EOF
    [ "$LOCAL_DB" -eq 0 ] && echo "ssl-ca=$RDS_CA_PATH" >> "$cnf"
    if mysql --defaults-extra-file="$cnf" -e "SELECT 1;" "$SITE" >/dev/null 2>&1; then
        ok "App user '$SITE' can connect to '$SITE'"
    else
        rm -f "$cnf"
        err "App user '$SITE' cannot connect — check host/firewall/SSL config"
    fi
    rm -f "$cnf"
}

step_credentials_file() {
    log "Saving credentials"
    cat > "$SITE_ROOT/.credentials" <<EOF
# Credentials for $SITE — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# DO NOT commit this file. It is in .gitignore by default.

DOMAIN=$DOMAIN
SITE=$SITE
DB_HOST=$RDS_HOST
DB_NAME=$SITE
DB_USER=$SITE
DB_PASS=$DB_PASS
EOF
    chmod 600 "$SITE_ROOT/.credentials"
    chown ubuntu:ubuntu "$SITE_ROOT/.credentials"
    ok "$SITE_ROOT/.credentials (mode 600, ubuntu only)"
}

step_wp_config() {
    if [ -z "$RDS_HOST" ]; then
        warn "No --rds-host, skipping wp-config.php"
        return
    fi

    if [ ! -f "$PUBLIC_DIR/wp-includes/version.php" ]; then
        warn "WordPress core not found in $PUBLIC_DIR — skipping wp-config.php"
        warn "  Run later: sudo -u ubuntu wp core download --path=$PUBLIC_DIR"
        warn "  Then re-run this script with --force to generate wp-config.php"
        return
    fi

    if [ -f "$PUBLIC_DIR/wp-config.php" ] && [ "$FORCE" -ne 1 ]; then
        warn "wp-config.php exists — keeping (use --force to regenerate)"
        return
    fi

    log "Generating wp-config.php (with proxy fix + RDS SSL + site URLs)"

    local extra
    extra=$(mktemp)
    cat > "$extra" <<PHP
// === ALB SSL termination → tell WordPress is_ssl() to return true ===
if (!empty(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}

// === Real client IP (from CloudFlare via ALB) ===
if (!empty(\$_SERVER['HTTP_CF_CONNECTING_IP'])) {
    \$_SERVER['REMOTE_ADDR'] = \$_SERVER['HTTP_CF_CONNECTING_IP'];
}

// === RDS SSL connection (CA bundle: /etc/ssl/certs/rds-global-bundle.pem) ===
$([ "$LOCAL_DB" -eq 0 ] && echo "define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL);" || echo "// MYSQL_CLIENT_FLAGS omitted — local DB mode")

// === Site URLs ===
define('WP_HOME',    'https://${DOMAIN}');
define('WP_SITEURL', 'https://${DOMAIN}');
define('FORCE_SSL_ADMIN', true);
define('DISABLE_WP_CRON', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
define('DISALLOW_FILE_EDIT', true);
PHP

    [ -f "$PUBLIC_DIR/wp-config.php" ] && rm -f "$PUBLIC_DIR/wp-config.php"

    sudo -u ubuntu wp config create \
        --path="$PUBLIC_DIR" \
        --dbname="$SITE" \
        --dbuser="$SITE" \
        --dbpass="$DB_PASS" \
        --dbhost="$RDS_HOST" \
        --dbcharset=utf8mb4 \
        --dbcollate=utf8mb4_unicode_ci \
        --extra-php < "$extra"

    rm -f "$extra"
    chown ubuntu:www-data "$PUBLIC_DIR/wp-config.php"
    chmod 640 "$PUBLIC_DIR/wp-config.php"
    ok "wp-config.php generated (640, ubuntu:www-data)"
}

step_apache_vhost() {
    log "Writing Apache vhost"

    local alias_line=""
    if [ -n "$ALIAS" ]; then
        local aliases
        aliases=$(echo "$ALIAS" | tr ',' ' ')
        alias_line="ServerAlias $aliases"
    fi

    cat > "/etc/apache2/sites-available/${SITE}.conf" <<APACHE
# Site: $SITE
# Generated by create-site.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
<VirtualHost *:80>
    ServerName $DOMAIN
    $alias_line
    DocumentRoot $PUBLIC_DIR

    ErrorLog  $SITE_ROOT/logs/error.log
    CustomLog $SITE_ROOT/logs/access.log combined

    <Directory $PUBLIC_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Block all dotfiles (.git, .env, .htaccess output, etc.)
    <DirectoryMatch "/\\.">
        Require all denied
    </DirectoryMatch>
    RedirectMatch 404 /\\.git(/|\$)
    RedirectMatch 404 /\\.env\$

    <FilesMatch \\.php\$>
        SetHandler "proxy:unix:/run/php/${SITE}.sock|fcgi://localhost"
    </FilesMatch>

    # Trust X-Forwarded-* from ALB
    SetEnvIf X-Forwarded-Proto "https" HTTPS=on
    RemoteIPHeader X-Forwarded-For
    RemoteIPInternalProxy $VPC_CIDR
</VirtualHost>
APACHE

    a2ensite -q "${SITE}"
    ok "Vhost written + enabled: /etc/apache2/sites-available/${SITE}.conf"
}

step_php_fpm_pool() {
    log "Writing PHP-FPM pool"

    cat > "/etc/php/${PHP_VERSION}/fpm/pool.d/${SITE}.conf" <<FPM
; Site: $SITE
; Generated by create-site.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
[${SITE}]
user = www-data
group = www-data
listen = /run/php/${SITE}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ondemand
pm.max_children = ${MAX_CHILDREN}
pm.process_idle_timeout = 30s
pm.max_requests = 500

php_admin_value[memory_limit] = ${MEMORY_LIMIT}
php_admin_value[upload_max_filesize] = ${UPLOAD_MAX}
php_admin_value[post_max_size] = ${UPLOAD_MAX}
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = ${SITE_ROOT}/logs/php-error.log
php_admin_value[upload_tmp_dir] = ${SITE_ROOT}/tmp
php_admin_value[session.save_path] = ${SITE_ROOT}/tmp
php_admin_flag[log_errors] = on
FPM

    ok "Pool written: /etc/php/${PHP_VERSION}/fpm/pool.d/${SITE}.conf"
}

step_reload_services() {
    log "Reloading Apache + PHP-FPM"
    apachectl configtest >/dev/null 2>&1 || err "Apache config test failed — check vhost"
    systemctl reload "php${PHP_VERSION}-fpm"
    systemctl reload apache2
    ok "Services reloaded"
}

step_fix_permissions() {
    log "Fixing permissions"
    # Prefer the short ct-fix-perm name (post install-tools.sh),
    # fall back to the legacy fix-permission-site name for older installs.
    if command -v ct-fix-perm >/dev/null 2>&1; then
        ct-fix-perm --site="$SITE"
    elif command -v fix-permission-site >/dev/null 2>&1; then
        fix-permission-site --site="$SITE"
    else
        warn "ct-fix-perm not installed — applying inline fallback"
        chown -R ubuntu:www-data "$SITE_ROOT"
        find "$SITE_ROOT" -path "*/.git" -prune -o -type d -exec chmod 2775 {} +
        find "$SITE_ROOT" -path "*/.git" -prune -o -type f -exec chmod 0664 {} +
        if [ -d "$PUBLIC_DIR/.git" ]; then
            chown -R ubuntu:ubuntu "$PUBLIC_DIR/.git"
            find "$PUBLIC_DIR/.git" -type d -exec chmod 700 {} +
            find "$PUBLIC_DIR/.git" -type f -exec chmod 600 {} +
        fi
        [ -f "$PUBLIC_DIR/wp-config.php" ]   && chmod 640 "$PUBLIC_DIR/wp-config.php"
        [ -f "$SITE_ROOT/.credentials" ]     && chmod 600 "$SITE_ROOT/.credentials"
        ok "Inline permissions applied"
    fi
}

step_summary() {
    log "Site $SITE created"
    echo ""
    echo "  Path:           $SITE_ROOT"
    echo "  Domain:         $DOMAIN"
    echo "  Aliases:        $(echo "$ALIAS" | tr ',' ' ')"
    echo "  Apache vhost:   /etc/apache2/sites-available/${SITE}.conf"
    echo "  PHP-FPM pool:   /etc/php/${PHP_VERSION}/fpm/pool.d/${SITE}.conf  (max_children=${MAX_CHILDREN})"
    echo "  PHP socket:     /run/php/${SITE}.sock"
    echo "  PHP limits:     memory=${MEMORY_LIMIT}, upload=${UPLOAD_MAX}"
    if [ -n "$RDS_HOST" ] && [ "$SKIP_DB" -ne 1 ]; then
        echo ""
        echo "  DB host:        $RDS_HOST"
        echo "  DB name:        $SITE   (== DB user)"
        echo "  DB user:        $SITE"
        echo "  DB pass:        (saved to $SITE_ROOT/.credentials)"
        if [ "$LOCAL_DB" -eq 1 ]; then
            echo "  SSL:            skipped (--local-db mode — not for production)"
        else
            echo "  SSL:            REQUIRE SSL on user; MYSQLI_CLIENT_SSL in wp-config"
        fi
    fi
    echo ""
    echo "Next steps:"
    if [ -n "$RDS_HOST" ] && [ -f "$PUBLIC_DIR/wp-config.php" ]; then
        echo "  1. Import existing DB:"
        echo "     cd $PUBLIC_DIR && sudo -u ubuntu wp db import path/to/dump.sql"
        echo "  2. Search-replace URLs (if migrating):"
        echo "     sudo -u ubuntu wp search-replace 'old.url' 'https://${DOMAIN}' --all-tables --skip-columns=guid"
        echo "  3. Restore uploads:"
        echo "     tar -xzf uploads.tar.gz -C $PUBLIC_DIR/wp-content/ && sudo ct-fix-perm --site=$SITE"
        echo "  4. Verify SSL DB connection:"
        echo "     cd $PUBLIC_DIR && sudo -u ubuntu wp db cli -e \"SHOW STATUS LIKE 'Ssl_cipher';\""
        echo "  5. Add WP-Cron to crontab:"
        echo "     */5 * * * * cd $PUBLIC_DIR && /usr/local/bin/wp cron event run --due-now >/dev/null 2>&1"
    else
        echo "  1. Place WordPress files in $PUBLIC_DIR (clone repo or wp core download)"
        echo "  2. Re-run with --rds-host=... to create DB + wp-config.php"
    fi
    echo "  6. Add DNS at CloudFlare: $DOMAIN → ALB DNS name (proxied)"
    echo ""
}

# ---------- Main ----------
require_root
parse_args "$@"
preflight
step_create_dirs
step_clone_repo
step_create_database
step_credentials_file
step_wp_config
step_apache_vhost
step_php_fpm_pool
step_reload_services
step_fix_permissions
step_summary
