#!/bin/bash
#
# bootstrap-ec2-wordpress.sh
#
# Provision a clean Ubuntu 24.04 EC2 instance for multi-site WordPress hosting
# under /home/ubuntu/webapps/<site>/.
#
# Stack installed:
#   - Apache2 (mpm_event)
#   - PHP-FPM 8.3 + extensions required by WordPress + common plugins
#   - WP-CLI (system-wide at /usr/local/bin/wp)
#   - Redis (server + PHP extension, for object caching)
#   - MySQL client (for DB connections to RDS)
#   - UFW firewall (22, 80, 443 only)
#   - Fail2ban (sshd jail)
#   - AWS RDS global CA bundle (for SSL DB connections)
#
# Configures:
#   - User group memberships (ubuntu ↔ www-data)
#   - /home/ubuntu/webapps/ directory
#   - Default umask 002 for ubuntu user
#   - Git safe.directory for the webapps tree
#   - 2 GB swap with low swappiness
#   - Apache hardening (ServerTokens Prod, ServerSignature Off)
#
# Idempotent: safe to re-run.
#
# Usage:
#   sudo bash bootstrap-ec2-wordpress.sh
#
# Optional environment overrides:
#   TIMEZONE=UTC                                                    # default: Asia/Ho_Chi_Minh
#   FIX_PERM_URL=https://raw.githubusercontent.com/.../fix-permission-site.sh
#                                                                   # if set, installs fix-permission-site
#

set -euo pipefail

# ---------- Config ----------
TIMEZONE="${TIMEZONE:-Asia/Ho_Chi_Minh}"
PHP_VERSION="8.3"
WEBAPPS_DIR="/home/ubuntu/webapps"
SWAP_SIZE_MB=2048
RDS_CA_URL="https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
RDS_CA_PATH="/etc/ssl/certs/rds-global-bundle.pem"
WP_CLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
FIX_PERM_URL="${FIX_PERM_URL:-}"

# ---------- Helpers ----------
log()  { echo -e "\n\033[1;36m==>\033[0m $*"; }
ok()   { echo -e "    \033[1;32m✓\033[0m $*"; }
warn() { echo -e "    \033[1;33m!\033[0m $*"; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root (use sudo)." >&2
        exit 1
    fi
}

require_ubuntu_24() {
    if ! grep -q '^VERSION_ID="24\.04"' /etc/os-release; then
        warn "This script is tuned for Ubuntu 24.04. Detected: $(. /etc/os-release; echo "$PRETTY_NAME")"
        warn "Continuing anyway, but some package names may differ."
    fi
}

# ---------- Steps ----------

step_system_update() {
    log "Updating system packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get full-upgrade -y -qq
    apt-get autoremove -y -qq
    ok "System updated"
}

step_timezone() {
    log "Setting timezone to $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE"
    ok "Timezone: $(timedatectl show -p Timezone --value)"
}

step_install_packages() {
    log "Installing Apache2 + PHP ${PHP_VERSION} + extensions + tooling"

    # Required PHP extensions for WordPress + common plugins:
    #   mysql      — DB driver
    #   curl       — HTTP client (REST API, plugin updates, payment gateways)
    #   gd         — image manipulation (thumbnails, image editor)
    #   mbstring   — multi-byte strings (Vietnamese, emoji, JSON)
    #   xml        — XML parsing (RSS, oEmbed, importer)
    #   zip        — archives (plugin/theme install, backups)
    #   intl       — internationalization (locales, date formatting)
    #   bcmath     — arbitrary precision math (WooCommerce tax/totals)
    #   soap       — SOAP client (some payment/shipping plugins)
    #   opcache    — opcode cache (large performance win)
    #   imagick    — better image quality than GD (unversioned package on noble)
    #   redis      — Redis client extension (for object cache plugins)

    apt-get install -y -qq \
        apache2 \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-soap \
        php${PHP_VERSION}-opcache \
        php-imagick \
        php-redis \
        mysql-client-core-8.0 \
        redis-server \
        git \
        unzip \
        acl \
        curl \
        wget \
        ca-certificates \
        ufw \
        fail2ban

    ok "Packages installed"
    ok "PHP version: $(php -v | head -1)"
}

step_configure_apache() {
    log "Configuring Apache for PHP-FPM (mpm_event)"

    # Disable mod_php and prefork (silently — they may not be enabled on a fresh install)
    a2dismod -q php${PHP_VERSION} 2>/dev/null || true
    a2dismod -q mpm_prefork 2>/dev/null || true

    # Enable required modules
    a2enmod -q proxy_fcgi setenvif rewrite headers expires deflate ssl mpm_event remoteip
    a2enconf -q php${PHP_VERSION}-fpm

    # Disable default site (we'll add per-site vhosts manually)
    a2dissite -q 000-default 2>/dev/null || true

    # Hide server version in headers + error pages
    sed -i 's/^ServerTokens .*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf
    sed -i 's/^ServerSignature .*/ServerSignature Off/' /etc/apache2/conf-available/security.conf

    # Restart + enable on boot
    systemctl restart php${PHP_VERSION}-fpm
    systemctl restart apache2
    systemctl enable apache2 php${PHP_VERSION}-fpm >/dev/null

    ok "Apache configured with PHP-FPM (mpm_event)"
}

step_install_wp_cli() {
    log "Installing WP-CLI"
    if [ -x /usr/local/bin/wp ] \
       && /usr/local/bin/wp --info --allow-root 2>/dev/null | grep -q '^WP-CLI version'; then
        ok "WP-CLI: $(/usr/local/bin/wp --info --allow-root 2>/dev/null | grep '^WP-CLI version') (skipping download)"
        return
    fi
    curl -fsSL "$WP_CLI_URL" -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
    ok "WP-CLI: $(/usr/local/bin/wp --info --allow-root 2>/dev/null | grep '^WP-CLI version' || echo installed)"
}

step_rds_ca_bundle() {
    log "Installing AWS RDS global CA bundle"
    if [ -s "$RDS_CA_PATH" ] && openssl x509 -in "$RDS_CA_PATH" -noout >/dev/null 2>&1; then
        ok "RDS CA bundle: $RDS_CA_PATH (already present, skipping download)"
        return
    fi
    wget -q "$RDS_CA_URL" -O "$RDS_CA_PATH"
    chmod 644 "$RDS_CA_PATH"
    chown root:root "$RDS_CA_PATH"
    ok "RDS CA bundle: $RDS_CA_PATH"
}

step_users_and_permissions() {
    log "Configuring user/group memberships"

    # Cross-membership so ubuntu ↔ www-data can collaborate on site files
    usermod -aG www-data ubuntu
    usermod -aG ubuntu www-data

    # /home/ubuntu must be traversable by www-data (default is often 700)
    chmod 755 /home/ubuntu

    # Default umask 002 → new files from ubuntu shell are group-writable
    for f in /home/ubuntu/.bashrc /home/ubuntu/.profile; do
        [ -f "$f" ] || continue
        if ! grep -qE '^umask 002' "$f"; then
            echo 'umask 002' >> "$f"
            chown ubuntu:ubuntu "$f"
        fi
    done

    # Git safe.directory for ubuntu (prevents "dubious ownership" warnings)
    if ! sudo -u ubuntu git config --global --get-all safe.directory 2>/dev/null \
         | grep -Fq "$WEBAPPS_DIR/*/public"; then
        sudo -u ubuntu git config --global --add safe.directory "$WEBAPPS_DIR/*/public"
    fi

    ok "Users + groups configured"
}

step_webapps_dir() {
    log "Creating $WEBAPPS_DIR"
    mkdir -p "$WEBAPPS_DIR"
    chown ubuntu:www-data "$WEBAPPS_DIR"
    chmod 2755 "$WEBAPPS_DIR"
    ok "$WEBAPPS_DIR ready ($(stat -c '%U:%G %a' $WEBAPPS_DIR))"
}

step_swap() {
    log "Configuring swap (${SWAP_SIZE_MB} MB)"
    # Detect ANY active swap (swapfile, partition, or vendor-provisioned device)
    # so vendor-shipped swap (e.g. /dev/vdb on some VPS images) doesn't lead to
    # a redundant /swapfile being added on top.
    if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
        ok "Swap already active: $(swapon --show --noheadings 2>/dev/null | awk '{print $1}' | paste -sd, -)"
    else
        fallocate -l "${SWAP_SIZE_MB}M" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        if ! grep -q '^/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        ok "Swap created and mounted"
    fi

    # Sensible swappiness for a web server (default 60 is too eager)
    sysctl -w vm.swappiness=10 >/dev/null
    if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    ok "vm.swappiness=10"
}

step_firewall() {
    log "Configuring UFW (22, 80, 443)"
    # Allow SSH BEFORE enabling default deny — protects existing SSH session
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    ok "UFW: $(ufw status | head -1)"
}

step_fail2ban() {
    log "Enabling fail2ban"
    systemctl enable --now fail2ban >/dev/null
    ok "fail2ban: $(systemctl is-active fail2ban)"
}

step_redis() {
    log "Enabling Redis"
    systemctl enable --now redis-server >/dev/null
    ok "Redis: $(redis-cli -h 127.0.0.1 ping 2>/dev/null || echo unreachable)"
}

step_fix_perm_script() {
    if [ -z "$FIX_PERM_URL" ]; then
        warn "FIX_PERM_URL not set — skipping fix-permission-site install"
        warn "  Re-run with: sudo FIX_PERM_URL=https://raw.githubusercontent.com/<your-fork>/.../fix-permission-site.sh \\"
        warn "                    bash bootstrap-ec2-wordpress.sh"
        return
    fi
    log "Installing fix-permission-site from $FIX_PERM_URL"
    wget -q "$FIX_PERM_URL" -O /usr/local/bin/fix-permission-site
    chmod +x /usr/local/bin/fix-permission-site
    ok "Available as: sudo fix-permission-site --site=<sitename>"
}

step_summary() {
    log "Bootstrap complete"
    echo ""
    echo "  Apache:       $(apache2 -v | head -1 | sed 's/Server version: //')"
    echo "  PHP-FPM:      $(php -v | head -1 | awk '{print $1, $2}')"
    echo "  WP-CLI:       $(/usr/local/bin/wp --info --allow-root 2>/dev/null | grep '^WP-CLI version' | awk '{print $3}')"
    echo "  Redis:        $(redis-cli ping 2>/dev/null)"
    echo "  Webroot:      $WEBAPPS_DIR  ($(stat -c '%U:%G %a' $WEBAPPS_DIR))"
    echo "  RDS CA:       $RDS_CA_PATH"
    local swap_summary
    swap_summary=$(swapon --show --noheadings 2>/dev/null | awk '{print $1"("$3")"}' | paste -sd, -)
    echo "  Swap:         ${swap_summary:-none}"
    echo "  UFW:          $(ufw status | head -1 | sed 's/Status: //')"
    echo "  fail2ban:     $(systemctl is-active fail2ban)"
    if [ -f /var/run/reboot-required ]; then
        echo ""
        warn "REBOOT REQUIRED — apt installed a new kernel or core library."
        if [ -s /var/run/reboot-required.pkgs ]; then
            warn "  Pending packages:"
            sed 's/^/      /' /var/run/reboot-required.pkgs
        fi
        warn "  Reboot when convenient: sudo reboot"
    fi
    echo ""
    echo "Next steps for each site (e.g. acmeshop):"
    echo "  1. mkdir -p $WEBAPPS_DIR/<site>/{public,logs,backups,tmp}"
    echo "  2. Clone repo into <site>/public/"
    echo "  3. Write Apache vhost  → /etc/apache2/sites-available/<site>.conf"
    echo "  4. Write PHP-FPM pool  → /etc/php/${PHP_VERSION}/fpm/pool.d/<site>.conf"
    echo "  5. Write wp-config.php (with proxy fix + MYSQL_CLIENT_FLAGS)"
    echo "  6. sudo a2ensite <site> && sudo systemctl reload apache2 php${PHP_VERSION}-fpm"
    echo "  7. sudo fix-permission-site --site=<site>"
    echo ""
}

# ---------- Main ----------
require_root
require_ubuntu_24

step_system_update
step_timezone
step_install_packages
step_configure_apache
step_install_wp_cli
step_rds_ca_bundle
step_users_and_permissions
step_webapps_dir
step_swap
step_firewall
step_fail2ban
step_redis
step_fix_perm_script
step_summary
