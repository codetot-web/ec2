# WordPress on AWS — Project Brief

> Consolidated context for any agent continuing this work. Read this first; it tells you what's been decided, what files exist, what's pending, and how the pieces connect.

---

## What we're building

A multi-site WordPress hosting setup on AWS where each site is migrated from BlueHost shared hosting to a single EC2 instance backed by RDS MySQL, fronted by an ALB and CloudFlare, with code managed in Git and backups going to S3.

**First migration target:** `masanconsumer` (`masanconsumer.com`), repo `github.com/codetot-clients/masanconsumer`.

Future sites land on the same EC2, each isolated by per-site Apache vhost + PHP-FPM pool, with one RDS database per site (database name and user are intentionally identical).

---

## Architecture

```
End user → CloudFlare (proxy, WAF, edge cache)
        → ALB (HTTPS only, ACM cert from external team)
        → EC2 (Ubuntu 24.04, Apache 2.4 + PHP-FPM, multi-site)
        → RDS MySQL 8.0 (private subnet, SSL enforced)

EC2 outbound:
  → S3 (backups, instance-role auth)
  → sg3.codetot.org (RunCloud staging VPS, rsync mirror)
  → GitHub (deploy keys per repo)
```

Per-site layout on EC2:

```
/home/ubuntu/webapps/<site>/
├── public/        # Apache DocumentRoot, .git lives here (locked to ubuntu)
├── logs/          # access.log, error.log, php-error.log
├── backups/       # local DB dumps (7-day retention)
├── tmp/           # PHP session_save_path, upload_tmp_dir
└── .credentials   # mode 600, ubuntu:ubuntu — DB pass etc
```

Apache vhost per site at `/etc/apache2/sites-available/<site>.conf`, PHP-FPM pool per site at `/etc/php/<ver>/fpm/pool.d/<site>.conf`, socket at `/run/php/<site>.sock`.

---

## Decisions locked in *(don't re-debate these)*

**Apache 2.4 + PHP-FPM (mpm_event), not NGINX.** Apache `mod_proxy_fcgi` to per-site Unix sockets. Chosen because the team is Apache-native; the per-site PHP-FPM pool gives the isolation benefit anyway.

**`ubuntu:www-data` shared ownership for site files; `ubuntu:ubuntu` for `.git`.** Per-site UNIX user (the litesoup model) was considered and deferred — too much workflow churn for a fleet just starting. Setgid `2775` on directories means new files inherit the `www-data` group; ACLs on uploads as belt-and-braces. `.git` is locked to `ubuntu` only so a misbehaving plugin running as `www-data` can't corrupt version control.

**DB name == DB user.** Each site `<site>` gets database `<site>` owned by user `<site>`. One name per project, enforced in the create script.

**RDS with SSL enforced.** `require_secure_transport = ON` on the parameter group, `MYSQL_CLIENT_FLAGS = MYSQLI_CLIENT_SSL` in wp-config, RDS global CA bundle at `/etc/ssl/certs/rds-global-bundle.pem`. The DB user is created with `REQUIRE SSL` so the server refuses non-SSL connections even if a client misconfigures.

**ALB terminates TLS, not the EC2.** ACM cert at the ALB (managed by external team). Apache listens on port 80 only and trusts `X-Forwarded-Proto` to know it's serving HTTPS. **No certbot on the box.**

**CloudFlare proxies the ALB.** Real client IP comes through `HTTP_CF_CONNECTING_IP` and is mapped to `REMOTE_ADDR` in wp-config so plugins, security tools, and access logs see the actual visitor. CloudFlare-IP-only firewall on the ALB security group prevents bypass.

**Git is the code distribution channel.** Each client gets a private repo at `github.com/codetot-clients/<client>` containing the entire WordPress tree minus uploads/caches/secrets. Deploy via `git clone` then `git pull`. WP-Admin plugin/theme installs **bypass Git** — pick `DISALLOW_FILE_MODS=true` (locked, dev-controlled) or capture-back-to-Git policy per site.

**WP-CLI for all DB operations.** `wp db export` / `wp db import` on both ends. Don't use `mysqldump` directly.

**`aws s3 sync` for incremental backups.** Not rsync (which doesn't talk to S3). Same delta-only behaviour, just over the S3 API. DB dumps are timestamped uploads + lifecycle policy for retention.

**Multi-PHP via Ondrej PPA.** Default Ubuntu 24.04 ships PHP 8.3. Older versions for legacy sites come from `ppa:ondrej/php` via `ct-install-php X.Y`. Each version runs its own systemd FPM service; per-vhost SetHandler routes to the right socket.

---

## Constraints

- **EC2 access:** Windows host → RDP → Bitvise SSH (with `.pem` key) → EC2. No direct internet SSH; `sg-ec2` allows port 22 only from the RDP jump host's egress IP.
- **SSL is external:** ACM cert + CloudFlare cert handled by another team. Track as a dependency, not as work.
- **Email:** open question — if BlueHost mailboxes are in use, email migration is a separate workstream that must complete *before* DNS cutover.

---

## Toolchain — five bash scripts

All scripts live at `github.com/codetot-web/runcloud-bash-scripts` (or whichever fork the team standardizes on) and install to `/usr/local/bin/` with a `ct-` prefix via `install-codetot-tools.sh`.

| Command | Source file | Purpose | Runs as | Frequency |
|---|---|---|---|---|
| `ct-bootstrap` | `bootstrap-ec2-wordpress.sh` | Provision a clean Ubuntu 24.04 EC2: Apache, PHP 8.3 + extensions, WP-CLI, Redis, RDS CA, users, ufw, fail2ban, swap | root | Once per EC2 |
| `ct-install-php` | `install-php-version.sh` | Add another PHP version side-by-side via Ondrej PPA, with all WP extensions | root | Per additional PHP version needed |
| `ct-create-site` | `create-site.sh` | Scaffold a new site: dirs, optional git clone, RDS DB+user, vhost, FPM pool, wp-config.php, permissions | root | Once per site |
| `ct-fix-perm` | `fix-permission-site.sh` | Re-apply `ubuntu:www-data` 2775/0664, lock `.git` to `ubuntu:ubuntu`, refresh ACLs | root | After git pull, restore, bulk file change |
| `ct-backup` | `backup-site.sh` | DB dump + uploads sync to S3 via instance IAM role | ubuntu (cron) | Weekly + optional daily DB-only |

The installer:

```bash
curl -fsSL https://raw.githubusercontent.com/codetot-web/runcloud-bash-scripts/main/install-codetot-tools.sh | sudo bash
```

Idempotent — re-running fetches the latest version of every script.

### Key flags by script

**`ct-create-site`** — the most parameterized:

```bash
sudo RDS_MASTER_PASS='xxx' ct-create-site \
    --site=masanconsumer \
    --domain=masanconsumer.com \
    --git-repo=git@github.com-masanconsumer:codetot-clients/masanconsumer.git \
    --rds-host=<rds-endpoint> \
    --php-version=8.3 \
    --memory-limit=512M --upload-max=64M --max-children=20
```

Master DB pass is read from env (so it's not in shell history); app DB pass is auto-generated and saved to `/home/ubuntu/webapps/<site>/.credentials` (mode 600, ubuntu only).

**`ct-backup`** — needs the bucket pre-created with lifecycle policy (see `BACKUP-SETUP.md`):

```bash
ct-backup --site=masanconsumer --bucket=codetot-backups-prod
```

Cron line for weekly Sunday 02:00 (in ubuntu's crontab):

```cron
0 2 * * 0 /usr/local/bin/ct-backup --site=masanconsumer --bucket=codetot-backups-prod >> /home/ubuntu/webapps/masanconsumer/logs/backup.log 2>&1
```

---

## Migration workflow — masanconsumer

The full phased checklist is in `migration-checklist-bluehost-to-aws.md`. Summary of the 14 phases:

1. **BlueHost audit** — inventory plugins, DB size, DNS, email; lower TTL to 300s.
2. **AWS infra** — VPC, subnets, security groups, EC2, RDS, ALB.
3. **EC2 base setup** — handled by `ct-bootstrap`.
4. **Permissions strategy** — `ubuntu:www-data` cross-membership, `.git` lock; handled by `ct-fix-perm`.
5. **Multi-site directory layout** — handled by `ct-create-site`.
6. **Git repo setup** — `.gitignore` for full WP project, `wp-config.sample.php` committed, real `wp-config.php` server-only, deploy keys per repo.
7. **Export from BlueHost** — `wp db export`, tar of uploads, transfer via Bitvise SFTP.
8. **Import to EC2** — `wp db import`, search-replace URLs, restore uploads tarball, set up cron for `wp cron event run`.
9. **Staging cross-access (sg3.codetot.org)** — SSH key from EC2 → sg3, rsync patterns for content sync, Git for code (never rsync code).
10. **CloudFlare config** — DNS, Full (Strict), WAF, cache rules, origin SG locked to CF IPs.
11. **SSL coordination** — track ACM + CF cert work with the external team.
12. **DNS cutover** — TTL down 48h before, hosts-file test, final delta DB sync, switch CF DNS, smoke-test, enable HSTS at T+24h.
13. **Post-migration verification** — SSL active, real client IPs in logs, DB SSL active (`SHOW STATUS LIKE 'Ssl_cipher'` returns non-empty), no mixed content, `.git` not exposed.
14. **Backups, monitoring, hardening** — cron for `ct-backup`, CloudWatch alarms, NinjaFirewall, `DISALLOW_FILE_EDIT`, 2FA on admin, kill BlueHost-era `admin` user.

---

## Files in this project

All in `/mnt/user-data/outputs/` from the conversation. They should be checked into a Git repo (most naturally `github.com/codetot-web/runcloud-bash-scripts` since that's where the install URL points).

| File | What | Pushed to repo? |
|---|---|---|
| `bootstrap-ec2-wordpress.sh` | EC2 base provisioner | Required at install URL |
| `install-php-version.sh` | Side-by-side PHP installer (Ondrej PPA) | Required at install URL |
| `create-site.sh` | Per-site scaffolding | Required at install URL |
| `fix-permission-site.sh` | Permission refresh | Required at install URL |
| `backup-site.sh` | DB + uploads backup to S3 | Required at install URL |
| `install-codetot-tools.sh` | Bootstrap installer for the five above | Required at install URL |
| `migration-checklist-bluehost-to-aws.md` | 14-phase playbook for masanconsumer | Should live in masanconsumer client repo or `docs/` of scripts repo |
| `BACKUP-SETUP.md` | S3 bucket + IAM + cron + restore docs | Should live in `docs/` of scripts repo |
| `PROJECT-BRIEF.md` (this file) | Consolidated context for agents | Should live in `docs/` of scripts repo |

Reading order for a fresh agent: this file → `migration-checklist-bluehost-to-aws.md` for the phased work → individual scripts as needed.

---

## Quick start — fresh EC2 to first live site

```bash
# 1. Clean Ubuntu 24.04 EC2, accessed via Bitvise SSH as ubuntu
# 2. Install the toolchain
curl -fsSL https://raw.githubusercontent.com/codetot-web/runcloud-bash-scripts/main/install-codetot-tools.sh | sudo bash

# 3. Provision the box (Apache + PHP 8.3 + RDS CA + users + firewall)
sudo ct-bootstrap

# 4. (Optional) Add older PHP for legacy sites
sudo ct-install-php 7.4

# 5. Create the site (DB + vhost + pool + wp-config + clone)
sudo RDS_MASTER_PASS='xxx' ct-create-site \
    --site=masanconsumer \
    --domain=masanconsumer.com \
    --git-repo=git@github.com-masanconsumer:codetot-clients/masanconsumer.git \
    --rds-host=<rds-endpoint>

# 6. Import existing DB + uploads from BlueHost (via Bitvise SFTP staging)
cd /home/ubuntu/webapps/masanconsumer/public
gunzip -c /home/ubuntu/webapps/masanconsumer/backups/blu*.sql.gz | sudo -u ubuntu wp db import -
sudo -u ubuntu wp search-replace 'http://masanconsumer.com' 'https://masanconsumer.com' --all-tables --skip-columns=guid

cd wp-content && rm -rf uploads && tar -xzf ../../../backups/uploads*.tar.gz
sudo ct-fix-perm --site=masanconsumer

# 7. Set up backups (after S3 bucket + IAM are ready — see BACKUP-SETUP.md)
crontab -e   # as ubuntu
# 0 2 * * 0 /usr/local/bin/ct-backup --site=masanconsumer --bucket=codetot-backups-prod >> /home/ubuntu/webapps/masanconsumer/logs/backup.log 2>&1

# 8. Verify
curl -I https://masanconsumer.com/                                    # 200 OK after DNS cutover
sudo -u ubuntu wp db cli -e "SHOW STATUS LIKE 'Ssl_cipher';"          # non-empty = SSL active
```

---

## Common ops reference

| Task | Command |
|---|---|
| Pull latest code | `cd /home/ubuntu/webapps/<site>/public && git pull && sudo ct-fix-perm --site=<site>` |
| Manual DB backup | `cd <site>/public && sudo -u ubuntu wp db export ../backups/manual-$(date +%F-%H%M).sql` |
| Tail PHP errors | `tail -f /home/ubuntu/webapps/<site>/logs/php-error.log` |
| Tail Apache errors | `tail -f /home/ubuntu/webapps/<site>/logs/error.log` |
| Test Apache config | `sudo apachectl configtest` |
| Restart PHP pool | `sudo systemctl reload php8.3-fpm` |
| Push prod → staging | See Phase 9 in migration checklist (rsync to sg3.codetot.org) |
| Verify DB SSL | `sudo -u ubuntu wp db cli -e "SHOW STATUS LIKE 'Ssl_cipher';"` |
| List installed PHP versions | `sudo ct-install-php` (no args) |

---

## Open decisions *(things the agent should ask before assuming)*

**`DISALLOW_FILE_MODS` policy for masanconsumer.** Locked (dev-only updates via Git pull) or open (allow WP-Admin installs, capture back to Git periodically)? Default in `create-site.sh` is currently *off* — it's commented in the generated wp-config. Pick one and uncomment.

**Email migration path.** If `masanconsumer.com` MX currently points at BlueHost, email migration is a separate workstream (Workspace, M365, Zoho, or SES inbound). Must complete before DNS cutover or business email goes dark.

**WP admin user audit.** BlueHost-era admin accounts often include a default `admin` user, weak passwords, and ex-employees. Audit `wp user list --role=administrator` post-migration; force password resets; enable 2FA.

**S3 bucket regional alignment.** Backup bucket should be in the same region as the EC2 to avoid cross-region egress charges. The `BACKUP-SETUP.md` examples use `ap-southeast-1` (Singapore) — confirm against the actual EC2 region.

**Backup retention beyond 1 year.** `BACKUP-SETUP.md` lifecycle expires backups at 365 days. If client contracts or industry rules require 7 years, change `Expiration.Days` to 2555 and add a `DEEP_ARCHIVE` transition at day 90.

---

## Known small cleanups *(safe to do anytime)*

- `bootstrap-ec2-wordpress.sh` still has a `FIX_PERM_URL` env-var step for installing the permission script independently. Now redundant since `install-codetot-tools.sh` handles it. Drop the step.
- `migration-checklist-bluehost-to-aws.md` references `fix-permission-site` and `backup-site` as the long command names. Search-and-replace to `ct-fix-perm` and `ct-backup`.
- `BACKUP-SETUP.md` Phase G.2 restore step: `sudo fix-permission-site --site=masanconsumer` should be `sudo ct-fix-perm --site=masanconsumer`.

These are documentation-only — they won't break anything if not done, but they're inconsistent with the installed command names.

---

## Anti-patterns to avoid

A few things came up during design that look reasonable but break the model:

- **Don't `chown -R www-data:www-data` site files.** Locks `ubuntu` out of `git pull`. Always `ubuntu:www-data`.
- **Don't `chmod 777` anywhere.** The setgid + group-writable strategy gives both users access without the security finding.
- **Don't run `wp-cli` as root or via `sudo wp`.** WP-CLI complains and some commands break. Always `sudo -u ubuntu wp ...`.
- **Don't put the RDS CA bundle at `~/rds-combined-ca-bundle.pem`.** `/home/ubuntu/` is mode 755 but private files inside aren't necessarily readable by `www-data`. Use `/etc/ssl/certs/rds-global-bundle.pem`.
- **Don't rsync code between EC2 and sg3 staging.** Code goes through Git only. Rsync is for content/uploads/DB dumps, never code.
- **Don't use AWS CLI v1 from apt.** It's older and slower. The `BACKUP-SETUP.md` install procedure pulls v2 directly from AWS.
- **Don't reset `ufw` mid-session over SSH.** `ufw --force reset` drops rules; if SSH isn't re-allowed before deny-default kicks in, you lock yourself out. The bootstrap script orders `ufw allow 22` *before* `ufw default deny`.

---

## Decisions deferred *(intentionally not solving yet)*

- **Per-site UNIX user model** (the litesoup approach). Better security, but every script in this toolchain assumes `ubuntu:www-data`. Migration to per-site users is a future project, not blocking masanconsumer.
- **Fleet management across multiple EC2 instances.** Currently scoped to a single EC2 hosting many sites. If a second EC2 lands, revisit.
- **CloudWatch backup-age alarm.** Mentioned in `BACKUP-SETUP.md` Phase F.2 as a Lambda or local cron pattern. Build the helper when production traffic arrives; not blocking initial cutover.
- **Cross-region or cross-account DR.** Single-region S3 backups for now. Cross-region is a config change to the bucket lifecycle if needed later.

---

## Contact points / who owns what

| Workstream | Owner |
|---|---|
| EC2 + scripts + Apache + PHP + WP migration | Code Tốt (Kevin) |
| ACM cert + ALB cert attachment | External SSL team |
| CloudFlare DNS + edge config | Code Tốt |
| RDS provisioning + parameter group | TBD (likely Code Tốt) |
| BlueHost decommission timing | Client (masanconsumer) — keep paid until 7 days post-cutover |
| Email migration (if applicable) | TBD per client |
