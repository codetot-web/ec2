# Runbook — EC2 setup for masanconsumer

End-to-end guide: provision a fresh Ubuntu 24.04 EC2 instance, install the
toolchain, create the masanconsumer site, and migrate data from staging.

## Prerequisites

Before starting, have these AWS resources ready:

| Resource | Notes |
|---|---|
| EC2 — Ubuntu 24.04 LTS (x86_64) | t3.medium or larger; at least 20 GB root volume |
| RDS — MySQL 8.0 | `require_secure_transport=ON`; EC2 security group must reach port 3306 |
| ALB | HTTPS listener (ACM cert); HTTP → HTTPS redirect; target group points to EC2 port 80 |
| CloudFlare | DNS proxied → ALB DNS name |
| S3 bucket | For backups (optional at install time) |
| IAM role on EC2 | Policy: `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the backup bucket |

---

## Phase 1 — Bootstrap the EC2

Run once per EC2 instance. Installs Apache, PHP 8.3-FPM, WP-CLI, Redis,
RDS CA bundle, UFW, Fail2ban, and swap.

### 1.1 SSH into the EC2

```bash
ssh ubuntu@<ec2-public-ip>
```

### 1.2 Download and run the bootstrap script

```bash
curl -fsSL https://raw.githubusercontent.com/codetot-web/ec2/main/bash-scripts/bootstrap-ec2-wordpress.sh \
  | sudo bash
```

Expected output ends with a summary table showing all components installed.
The script is idempotent — safe to re-run if interrupted.

### 1.3 Reboot if a new kernel was installed

The summary will warn if `/var/run/reboot-required` exists:

```bash
sudo reboot
```

### 1.4 Verify

```bash
php -v                          # PHP 8.3.x
wp --info --allow-root          # WP-CLI 2.x
redis-cli ping                  # PONG
sudo ufw status                 # 22, 80, 443 ALLOW
openssl x509 -noout -in /etc/ssl/certs/rds-global-bundle.pem 2>/dev/null && echo ok
```

---

## Phase 2 — Create the masanconsumer site

Run once per site. Scaffolds dirs, vhost, PHP-FPM pool, RDS database,
wp-config.php, and `.htaccess`.

### 2.1 Set up the GitHub deploy key

Generate a deploy key on the EC2:

```bash
sudo -u ubuntu ssh-keygen -t ed25519 -C "deploy@ec2-masanconsumer" \
  -f /home/ubuntu/.ssh/id_ed25519_masanconsumer -N ""
cat /home/ubuntu/.ssh/id_ed25519_masanconsumer.pub
```

Add the printed public key to GitHub as a **read-only** deploy key:
`github.com/codetot-clients/masanconsumer/settings/keys`

Then add the SSH alias on the EC2:

```bash
sudo -u ubuntu tee -a /home/ubuntu/.ssh/config <<'EOF'

Host github.com-masanconsumer
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_masanconsumer
    IdentitiesOnly yes
EOF
```

Verify:

```bash
sudo -u ubuntu ssh -T git@github.com-masanconsumer
# Hi codetot-clients/masanconsumer! You've successfully authenticated...
```

### 2.2 Download create-site.sh

```bash
curl -fsSL https://raw.githubusercontent.com/codetot-web/ec2/main/bash-scripts/create-site.sh \
  -o /tmp/create-site.sh
```

### 2.3 Run create-site.sh

```bash
sudo RDS_MASTER_PASS='<rds-admin-password>' bash /tmp/create-site.sh \
  --site=masanconsumer \
  --domain=masanconsumer.com \
  --git-repo=git@github.com-masanconsumer:codetot-clients/masanconsumer.git \
  --git-branch=master \
  --table-prefix=B4y_ \
  --rds-host=<rds-endpoint>.rds.amazonaws.com \
  --php-version=8.3 \
  --memory-limit=512M \
  --upload-max=64M \
  --max-children=20
```

The script creates:

| Path | Purpose |
|---|---|
| `/home/ubuntu/webapps/masanconsumer/{public,logs,backups,tmp}` | Site tree (2775 ubuntu:www-data) |
| `/etc/apache2/sites-available/masanconsumer.conf` | Apache vhost |
| `/etc/php/8.3/fpm/pool.d/masanconsumer.conf` | PHP-FPM pool (Unix socket) |
| `/home/ubuntu/webapps/masanconsumer/public/wp-config.php` | DB + proxy + SSL config (640) |
| `/home/ubuntu/webapps/masanconsumer/public/.htaccess` | WordPress mod_rewrite rules |
| `/home/ubuntu/webapps/masanconsumer/.credentials` | Generated DB password (600) |

### 2.4 Verify the scaffold

```bash
sudo -u ubuntu wp option get siteurl \
  --path=/home/ubuntu/webapps/masanconsumer/public
# https://masanconsumer.com

sudo apache2ctl configtest   # Syntax OK
systemctl is-active php8.3-fpm apache2
```

---

## Phase 3 — Migrate data from staging

Runs from your **local machine** (the dev machine that has SSH access to both
staging and EC2). Uses `tools/migrate-site.sh` from this repo.

### 3.1 Clone the repo locally (if not already)

```bash
git clone https://github.com/codetot-web/ec2.git
cd ec2
```

### 3.2 Configure .env

```bash
cp .env.sample .env
```

Edit `.env`:

```dotenv
# Staging (current VPS)
STAGING_SSH=ubuntu@sg10.codetot.org
STAGING_SSH_PASS=<sg10-password>
STAGING_DOMAIN=msc.codetot.org
STAGING_WP_PATH=/home/ubuntu/webapps/masanconsumer/public

# Target EC2
EC2_SSH=ubuntu@<ec2-public-ip>
# EC2_SSH_KEY=/path/to/key.pem   # if not in ssh-agent

# RDS
RDS_HOST=<db-identifier>.<region>.rds.amazonaws.com
RDS_MASTER_USER=admin
RDS_MASTER_PASS=<rds-admin-password>

# Site
SITE=masanconsumer
PROD_DOMAIN=masanconsumer.com
GIT_REPO=git@github.com-masanconsumer:codetot-clients/masanconsumer.git
GIT_BRANCH=master
TABLE_PREFIX=B4y_
PHP_VERSION=8.3
```

### 3.3 Dry-run first

```bash
bash tools/migrate-site.sh --dry-run
```

### 3.4 Run the migration

```bash
bash tools/migrate-site.sh
```

What it does:

1. Confirms SSH reachability to both hosts
2. Authorises staging → EC2 direct SSH (for rsync)
3. Uploads and runs `create-site.sh` on EC2 with `--force` (re-provision if already done)
4. Exports DB from staging MySQL via `wp db export`
5. Transfers dump staging → EC2, imports into RDS via `wp db import`
6. Search-replaces `https://msc.codetot.org` → `https://masanconsumer.com`
7. Rsyncs `wp-content/uploads/` directly staging → EC2 (incremental)
8. Writes `.htaccess`, flushes rewrites and cache, fixes permissions
9. Smoke-tests siteurl, latest post, and uploads size

To re-sync data only (skip re-provisioning):

```bash
bash tools/migrate-site.sh --skip-provision
```

To re-sync uploads only:

```bash
bash tools/migrate-site.sh --skip-provision --skip-db
```

---

## Phase 4 — DNS cutover

### 4.1 Verify the site on EC2 before cutover

Add a temporary entry to your local `/etc/hosts`:

```
<ec2-public-ip>  masanconsumer.com
```

Visit `https://masanconsumer.com` — confirm it loads correctly, then remove the hosts entry.

### 4.2 Update CloudFlare DNS

In CloudFlare dashboard for `masanconsumer.com`:

1. Set the `A` (or `CNAME`) record to point to the **ALB DNS name** (not the EC2 IP directly)
2. Enable the orange cloud (proxy) — CloudFlare terminates TLS, passes HTTP to ALB
3. Set SSL/TLS mode to **Full** (not Full Strict — ALB has ACM cert, EC2 is plain HTTP)

TTL: set to 60s before cutover, restore to Auto after.

### 4.3 Verify live

```bash
curl -sI https://masanconsumer.com/ | head -5
# HTTP/2 200
```

---

## Phase 5 — Post-cutover tasks

### WP-Cron

Add to ubuntu's crontab on EC2 (`sudo -u ubuntu crontab -e`):

```
*/5 * * * * cd /home/ubuntu/webapps/masanconsumer/public && /usr/local/bin/wp cron event run --due-now >/dev/null 2>&1
```

### S3 backups

```bash
# Manual test
ct-backup --site=masanconsumer --bucket=<your-backup-bucket>

# Add to ubuntu's crontab
0 3 * * * ct-backup --site=masanconsumer --bucket=<your-backup-bucket>
```

### Verify RDS SSL is active

```bash
sudo -u ubuntu wp db cli \
  --path=/home/ubuntu/webapps/masanconsumer/public \
  -e "SHOW STATUS LIKE 'Ssl_cipher';"
# Value should be non-empty (e.g. TLS_AES_256_GCM_SHA384)
```

---

## Quick reference

| Task | Command (run on EC2 as root unless noted) |
|---|---|
| Re-bootstrap | `sudo bash /tmp/bootstrap-ec2-wordpress.sh` |
| Re-create site config | `sudo RDS_MASTER_PASS='xxx' bash /tmp/create-site.sh --site=masanconsumer ... --force` |
| Fix permissions | `sudo ct-fix-perm --site=masanconsumer` |
| Manual backup | `ct-backup --site=masanconsumer --bucket=<bucket>` (as ubuntu) |
| Resync uploads only | `bash tools/migrate-site.sh --skip-provision --skip-db` (local) |
| Verify DB SSL | `sudo -u ubuntu wp db cli -e "SHOW STATUS LIKE 'Ssl_cipher';"` |
| Reload services | `sudo systemctl reload apache2 php8.3-fpm` |
| Check error log | `tail -f /home/ubuntu/webapps/masanconsumer/logs/error.log` |
