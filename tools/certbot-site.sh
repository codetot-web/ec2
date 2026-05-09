#!/bin/bash
#
# certbot-site.sh — Install certbot and obtain/renew a Let's Encrypt cert
#                   for a site already served by Apache on this host.
#
# Use on VPS/bare-metal hosts only. On production EC2 behind an ALB,
# TLS is terminated by ACM — do NOT run this there.
#
# Usage:
#   sudo bash certbot-site.sh --site=NAME --domain=DOMAIN --email=EMAIL [options]
#
# Examples:
#   sudo bash certbot-site.sh --site=masanconsumer --domain=msc.example.com --email=ops@example.com
#   sudo bash certbot-site.sh --site=masanconsumer --domain=msc.example.com --email=ops@example.com --dry-run

set -euo pipefail

SITE=""
DOMAIN=""
ALIAS=""
ALIAS_SET=0
EMAIL=""
DRY_RUN=0

log()  { echo -e "\n\033[1;36m==>\033[0m $*"; }
ok()   { echo -e "    \033[1;32m✓\033[0m $*"; }
warn() { echo -e "    \033[1;33m!\033[0m $*"; }
err()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo bash $(basename "$0") --site=NAME --domain=DOMAIN --email=EMAIL [options]

Required:
  --site=NAME      Site name (must match the Apache vhost filename: <site>.conf)
  --domain=DOMAIN  Primary domain for the certificate
  --email=EMAIL    Contact email for Let's Encrypt expiry notices

Optional:
  --alias=LIST     Comma-separated extra SANs (e.g. www.domain.com)
                   Default: www.<domain>
  --no-alias       Skip the default www.<domain> alias
  --dry-run        Run certbot in dry-run mode (no cert issued)
  -h, --help       Show this and exit
EOF
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --site=*)    SITE="${arg#*=}" ;;
            --domain=*)  DOMAIN="${arg#*=}" ;;
            --alias=*)   ALIAS="${arg#*=}"; ALIAS_SET=1 ;;
            --no-alias)  ALIAS=""; ALIAS_SET=1 ;;
            --email=*)   EMAIL="${arg#*=}" ;;
            --dry-run)   DRY_RUN=1 ;;
            --help|-h)   usage; exit 0 ;;
            *)           usage; err "Unknown argument: $arg" ;;
        esac
    done

    [ -n "$SITE" ]   || { usage; err "Missing --site"; }
    [ -n "$DOMAIN" ] || { usage; err "Missing --domain"; }
    [ -n "$EMAIL" ]  || { usage; err "Missing --email"; }

    [ "$ALIAS_SET" -eq 0 ] && ALIAS="www.${DOMAIN}"
    [ "$EUID" -eq 0 ] || err "Run as root (use sudo)"
}

step_install_certbot() {
    log "Installing certbot + Apache plugin"
    if command -v certbot >/dev/null 2>&1; then
        ok "certbot already installed ($(certbot --version 2>&1))"
        return
    fi
    apt-get install -y certbot python3-certbot-apache
    ok "certbot installed ($(certbot --version 2>&1))"
}

step_check_vhost() {
    log "Checking Apache vhost for $SITE"
    local vhost="/etc/apache2/sites-enabled/${SITE}.conf"
    [ -f "$vhost" ] || err "Vhost not enabled: $vhost — run create-site.sh first"
    ok "Vhost present: $vhost"
}

step_get_cert() {
    log "Obtaining Let's Encrypt cert for $DOMAIN"

    # Build -d flags from domain + comma-separated aliases
    local d_flags="-d $DOMAIN"
    if [ -n "$ALIAS" ]; then
        for san in $(echo "$ALIAS" | tr ',' ' '); do
            d_flags="$d_flags -d $san"
        done
    fi

    local dry_flag=""
    [ "$DRY_RUN" -eq 1 ] && dry_flag="--dry-run"

    # shellcheck disable=SC2086
    certbot --apache \
        $d_flags \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive \
        --redirect \
        $dry_flag

    if [ "$DRY_RUN" -eq 1 ]; then
        warn "Dry-run complete — no cert was issued"
    else
        ok "Certificate obtained and Apache reloaded"
    fi
}

step_verify_renewal() {
    [ "$DRY_RUN" -eq 1 ] && return
    log "Verifying auto-renewal timer"
    if systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null || \
       systemctl is-active --quiet certbot.timer 2>/dev/null; then
        ok "Auto-renewal timer active"
    elif crontab -l 2>/dev/null | grep -q certbot; then
        ok "Auto-renewal via cron"
    else
        warn "No renewal timer found — add a cron entry:"
        warn "  0 3 * * * certbot renew --quiet"
    fi
}

step_summary() {
    [ "$DRY_RUN" -eq 1 ] && return
    log "Certificate summary"
    certbot certificates --domain "$DOMAIN" 2>/dev/null | grep -E "Domains|Expiry|Certificate Path" || true
    echo ""
    echo "  Renewal command:  certbot renew --quiet"
    echo "  Force renew:      certbot renew --force-renewal --cert-name $DOMAIN"
    echo "  Revoke:           certbot revoke --cert-name $DOMAIN"
    echo ""
}

parse_args "$@"
step_install_certbot
step_check_vhost
step_get_cert
step_verify_renewal
step_summary
