# Runbook — Provision a new WordPress site on EC2 + RDS

End-to-end guide: bootstrap a fresh Ubuntu 24.04 EC2, create a site,
set up the RDS database, migrate data from a staging server, and cut over DNS.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Bootstrap the EC2](#2-bootstrap-the-ec2)
3. [Set up the deploy key](#3-set-up-the-deploy-key)
4. [Create the site scaffold](#4-create-the-site-scaffold)
5. [Create the RDS database and user](#5-create-the-rds-database-and-user)
6. [Sync uploads from staging](#6-sync-uploads-from-staging)
7. [Sync the database from staging](#7-sync-the-database-from-staging)
8. [DNS cutover](#8-dns-cutover)
9. [Post-cutover tasks](#9-post-cutover-tasks)
10. [Quick reference](#10-quick-reference)

---

## 1. Prerequisites

| Resource | Notes |
|---|---|
| EC2 — Ubuntu 24.04 LTS (x86_64) | t3.medium or larger; 20 GB+ root volume |
| RDS — MySQL 8.0 | `require_secure_transport=ON`; EC2 security group allows port 3306 |
| ALB | HTTPS listener (ACM cert); HTTP → HTTPS redirect; target group → EC2 port 80 |
| CloudFlare | DNS proxied → ALB DNS name |
| S3 bucket | For backups (optional at install time) |
| IAM role on EC2 | `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the backup bucket |
| GitHub deploy key | Read-only key on the site's private repo |

**Variables used throughout this document:**

| Placeholder | Description | Example |
|---|---|---|
| `<SITE>` | Site identifier — used for path, DB name, DB user, FPM pool | `acmeshop` |
| `<DOMAIN>` | Production domain | `acmeshop.com` |
| `<STAGING_DOMAIN>` | Staging domain to replace during migration | `staging.acmeshop.com` |
| `<STAGING_SSH>` | SSH address of staging server | `ubuntu@10.0.0.1` |
| `<GIT_REPO>` | SSH URL of the WordPress repo | `git@github.com-<SITE>:org/<SITE>.git` |
| `<GIT_BRANCH>` | Branch to deploy | `main` or `master` |
| `<TABLE_PREFIX>` | WordPress table prefix in the DB | `wp_` |
| `<RDS_HOST>` | RDS endpoint | `db.xxx.ap-southeast-1.rds.amazonaws.com` |
| `<RDS_MASTER_PASS>` | RDS admin password | _(from AWS Secrets Manager)_ |
| `<DB_PASS>` | Generated per-site DB password | _(generated in step 5)_ |
| `<PHP_VERSION>` | PHP version for this site | `8.3` |

---

## 2. Bootstrap the EC2

Run **once per EC2 instance**. Installs Apache, PHP-FPM, WP-CLI, Redis,
RDS CA bundle, UFW, Fail2ban, and 2 GB swap.

```bash
curl -fsSL https://raw.githubusercontent.com/codetot-web/ec2-toolkit/main/bash-scripts/bootstrap-ec2-wordpress.sh | sudo bash
```

Reboot if the summary warns about a pending kernel upgrade:

```bash
sudo reboot
```

**Verify:**

```bash
php -v && wp --info --allow-root && redis-cli ping && sudo ufw status
```

---

## 3. Set up the deploy key

Generate a deploy key on the EC2 for this site's private repo:

```bash
sudo -u ubuntu ssh-keygen -t ed25519 -C "deploy@ec2-<SITE>" -f /home/ubuntu/.ssh/id_ed25519_<SITE> -N ""
cat /home/ubuntu/.ssh/id_ed25519_<SITE>.pub
```

Add the printed public key to the GitHub repo as a **read-only** deploy key:
`github.com/<org>/<SITE>/settings/keys`

Add the SSH config alias on EC2:

```bash
sudo -u ubuntu tee -a /home/ubuntu/.ssh/config <<EOF

Host github.com-<SITE>
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_<SITE>
    IdentitiesOnly yes
EOF
```

Verify:

```bash
sudo -u ubuntu ssh -T git@github.com-<SITE>
# Hi <org>/<SITE>! You've successfully authenticated...
```

---

## 4. Create the site scaffold

Downloads `create-site.sh` and scaffolds dirs, vhost, PHP-FPM pool,
wp-config.php, and `.htaccess`.

```bash
curl -fsSL https://raw.githubusercontent.com/codetot-web/ec2-toolkit/main/bash-scripts/create-site.sh -o /tmp/create-site.sh
```

```bash
sudo RDS_MASTER_PASS='<RDS_MASTER_PASS>' bash /tmp/create-site.sh \
  --site=<SITE> \
  --domain=<DOMAIN> \
  --git-repo=<GIT_REPO> \
  --git-branch=<GIT_BRANCH> \
  --table-prefix=<TABLE_PREFIX> \
  --rds-host=<RDS_HOST> \
  --php-version=<PHP_VERSION>
```

**Created by the script:**

| Path | Purpose |
|---|---|
| `/home/ubuntu/webapps/<SITE>/public/` | WordPress document root |
| `/home/ubuntu/webapps/<SITE>/{logs,backups,tmp}/` | Site directories |
| `/etc/apache2/sites-available/<SITE>.conf` | Apache vhost |
| `/etc/php/<PHP_VERSION>/fpm/pool.d/<SITE>.conf` | PHP-FPM pool |
| `/home/ubuntu/webapps/<SITE>/public/wp-config.php` | DB + proxy + SSL config |
| `/home/ubuntu/webapps/<SITE>/public/.htaccess` | WordPress mod_rewrite rules |
| `/home/ubuntu/webapps/<SITE>/.credentials` | Generated DB password (mode 600) |

---

## 5. Create the RDS database and user

Connect to RDS as the admin user:

```bash
mysql -h <RDS_HOST> -u admin -p
```

### 5.1 Generate a secure password

Run this before connecting to MySQL and save the output:

```bash
openssl rand -base64 32 | tr -d '/+=' | head -c 32
```

### 5.2 Create database, user, and grants

```sql
CREATE DATABASE IF NOT EXISTS `<SITE>`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '<SITE>'@'%' IDENTIFIED BY '<DB_PASS>' REQUIRE SSL;
ALTER USER '<SITE>'@'%' IDENTIFIED BY '<DB_PASS>' REQUIRE SSL;

GRANT ALL PRIVILEGES ON `<SITE>`.* TO '<SITE>'@'%';
FLUSH PRIVILEGES;
```

> **Note:** `REQUIRE SSL` is mandatory — RDS has `require_secure_transport=ON`.
> DB name and DB user are intentionally identical to the site name.

### 5.3 Verify collation

```sql
SHOW CREATE DATABASE `<SITE>`;
-- Should show: DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci
```

### 5.4 Verify app user connection

```bash
mysql -h <RDS_HOST> -u <SITE> -p'<DB_PASS>' <SITE> -e "SELECT 1;"
```

### 5.5 Save credentials to the site

```bash
sudo tee /home/ubuntu/webapps/<SITE>/.credentials <<EOF
DB_HOST=<RDS_HOST>
DB_NAME=<SITE>
DB_USER=<SITE>
DB_PASS=<DB_PASS>
EOF
sudo chmod 600 /home/ubuntu/webapps/<SITE>/.credentials
sudo chown ubuntu:ubuntu /home/ubuntu/webapps/<SITE>/.credentials
```

---

## 6. Sync uploads from staging

### 6.1 One-time: set up SSH trust from EC2 → staging

```bash
sudo -u ubuntu bash -c '[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""'
```

```bash
sudo apt-get install -y sshpass
```

```bash
sudo -u ubuntu sshpass -p '<STAGING_SSH_PASS>' ssh-copy-id -o StrictHostKeyChecking=no <STAGING_SSH>
```

### 6.2 Rsync uploads (incremental — safe to re-run)

```bash
sudo -u ubuntu rsync -az --info=progress2 <STAGING_SSH>:/home/ubuntu/webapps/<SITE>/public/wp-content/uploads/ /home/ubuntu/webapps/<SITE>/wp-content/uploads/
```

> Adjust the source path to match the staging server's directory structure.

---

## 7. Sync the database from staging

### 7.1 Export DB on staging

```bash
ssh <STAGING_SSH> "sudo -u ubuntu wp db export /tmp/<SITE>-$(date +%Y%m%d).sql --path=/home/ubuntu/webapps/<SITE>/public --allow-root"
```

### 7.2 Copy dump to EC2

```bash
scp <STAGING_SSH>:/tmp/<SITE>-$(date +%Y%m%d).sql /tmp/<SITE>-$(date +%Y%m%d).sql
```

### 7.3 Import into RDS

```bash
sudo -u ubuntu wp db import /tmp/<SITE>-$(date +%Y%m%d).sql --path=/home/ubuntu/webapps/<SITE>
```

### 7.4 Search-replace staging domain → production domain

```bash
sudo -u ubuntu wp search-replace 'https://<STAGING_DOMAIN>' 'https://<DOMAIN>' --all-tables --skip-columns=guid --path=/home/ubuntu/webapps/<SITE>
```

### 7.5 Clean up

```bash
rm /tmp/<SITE>-$(date +%Y%m%d).sql
```

---

## 8. DNS cutover

### 8.1 Verify the site before cutover

Add a temporary entry to your local `/etc/hosts`:

```
<EC2_PUBLIC_IP>  <DOMAIN>
```

Visit `https://<DOMAIN>` in a browser. Confirm the site loads correctly, then remove the entry.

### 8.2 Update CloudFlare DNS

1. Point `<DOMAIN>` CNAME → ALB DNS name
2. Enable the orange cloud (proxy) — CloudFlare terminates TLS
3. Set SSL/TLS encryption mode to **Full**
4. Set TTL to 60s before cutover; restore to Auto afterwards

### 8.3 Confirm propagation

```bash
curl -sI https://<DOMAIN>/ | head -3
# HTTP/2 200
```

---

## 9. Post-cutover tasks

### WP-Cron

Add to ubuntu's crontab (`sudo -u ubuntu crontab -e`):

```
*/5 * * * * cd /home/ubuntu/webapps/<SITE> && /usr/local/bin/wp cron event run --due-now >/dev/null 2>&1
```

### S3 backups

```bash
# Test manually first
ct-backup --site=<SITE> --bucket=<S3_BUCKET>

# Then add to ubuntu's crontab
0 3 * * * ct-backup --site=<SITE> --bucket=<S3_BUCKET>
```

### Verify RDS SSL is active

```bash
sudo -u ubuntu wp db cli --path=/home/ubuntu/webapps/<SITE> -e "SHOW STATUS LIKE 'Ssl_cipher';"
# Value column must be non-empty
```

---

## 10. Quick reference

| Task | Command |
|---|---|
| Re-bootstrap EC2 | `sudo bash /tmp/bootstrap-ec2-wordpress.sh` |
| Re-scaffold site config | `sudo RDS_MASTER_PASS='xxx' bash /tmp/create-site.sh --site=<SITE> ... --force` |
| Fix permissions | `sudo ct-fix-perm --site=<SITE>` |
| Reload services | `sudo systemctl reload apache2 php<PHP_VERSION>-fpm` |
| Manual backup | `ct-backup --site=<SITE> --bucket=<S3_BUCKET>` |
| Re-sync uploads | _(step 6.2 — rsync is incremental)_ |
| Re-sync DB | _(steps 7.1–7.4)_ |
| Verify DB SSL | `sudo -u ubuntu wp db cli -e "SHOW STATUS LIKE 'Ssl_cipher';"` |
| Tail error log | `tail -f /home/ubuntu/webapps/<SITE>/logs/error.log` |
| Check PHP-FPM socket | `ls /run/php/<SITE>.sock` |
