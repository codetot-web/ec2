# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Bash scripts and documentation for migrating WordPress sites from BlueHost shared hosting to a single multi-site AWS EC2 host (Ubuntu 24.04, Apache + PHP-FPM, RDS MySQL, ALB, CloudFlare, S3 backups).

Scripts here are installed on EC2 hosts as `ct-`-prefixed commands in `/usr/local/bin/` via the toolchain installer (`install-tools.sh`, hosted alongside the scripts at `github.com/codetot-web/runcloud-bash-scripts`).

`PROJECT-BRIEF.md` is the canonical context document — read it before making non-trivial changes. `bash-scripts/BACKUP-SETUP.md` is the operational runbook for the S3 backup pipeline.

## Repository contents

```
PROJECT-BRIEF.md              # Canonical project context — start here
bash-scripts/
  bootstrap-ec2-wordpress.sh  # ct-bootstrap — provisions a fresh EC2
  create-site.sh              # ct-create-site — scaffolds one site
  backup-site.sh              # ct-backup — DB + uploads to S3
  BACKUP-SETUP.md             # Backup operational runbook
```

The brief references additional scripts (`install-php-version.sh`, `fix-permission-site.sh`, `install-tools.sh`) and a `migration-checklist-bluehost-to-aws.md` that **do not exist in this directory yet**. If a task requires them, confirm with the user before assuming their content.

## Architecture, in one paragraph

End user → CloudFlare → ALB (TLS termination, ACM cert) → EC2 (Apache mpm_event + per-site PHP-FPM pools on Unix sockets) → RDS MySQL 8.0 (SSL enforced). Each site lives at `/home/ubuntu/webapps/<site>/{public,logs,backups,tmp}` with `ubuntu:www-data` shared ownership (setgid 2775 dirs, 0664 files); `.git` is locked to `ubuntu:ubuntu` so `www-data` can't corrupt VCS. DB name == DB user == `<site>`. Code is distributed via Git pull; uploads/DB go via S3.

## Locked-in decisions — do not re-debate

These are settled. If the user seems to be revisiting one, surface the existing decision before changing course.

- **Apache + PHP-FPM, not NGINX.** `mod_proxy_fcgi` to per-site Unix sockets at `/run/php/<site>.sock`.
- **`ubuntu:www-data` for site files; `ubuntu:ubuntu` for `.git`.** Never `chown -R www-data:www-data` site files — it locks `ubuntu` out of `git pull`.
- **DB name == DB user == site name.** Enforced in `create-site.sh`.
- **RDS SSL is mandatory.** `require_secure_transport=ON`, `MYSQLI_CLIENT_SSL` flag in wp-config, CA bundle at `/etc/ssl/certs/rds-global-bundle.pem` (not `~/`).
- **ALB terminates TLS.** Apache listens on port 80 only and trusts `X-Forwarded-Proto`. **No certbot on the box.**
- **CloudFlare proxies the ALB.** Real client IP via `HTTP_CF_CONNECTING_IP` mapped to `REMOTE_ADDR` in wp-config.
- **WP-CLI for all DB ops** (`wp db export`/`import`), never raw `mysqldump`. Always run as `sudo -u ubuntu wp ...` — never as root, never via `sudo wp`.
- **`aws s3 sync` for incremental backups** (rsync doesn't speak S3). DB dumps are timestamped uploads; lifecycle handles retention.
- **Multi-PHP via Ondrej PPA.** Default is 8.3 from Ubuntu 24.04. Older versions added side-by-side via `ct-install-php X.Y`.
- **AWS CLI v2 only**, installed from AWS direct URL. Apt's `awscli` (v1) is forbidden.

## Anti-patterns — these break the model

- `chown -R www-data:www-data` on site files (breaks git pull).
- `chmod 777` anywhere (the setgid + group-writable strategy already gives both users access).
- Running `wp-cli` as root or `sudo wp` — always `sudo -u ubuntu wp ...`.
- Putting the RDS CA bundle anywhere under `/home/ubuntu/` — `www-data` may not be able to read it.
- Rsync of code between EC2 ↔ staging (staging.example.com). Code goes through Git only. Rsync is for content/uploads/DB dumps.
- `ufw --force reset` mid-session over SSH — the bootstrap script orders `ufw allow 22` *before* `ufw default deny` for a reason.

## Working with the bash scripts

All scripts use `set -euo pipefail`, follow a `step_*` function pattern with a `log/ok/warn/err` helper convention, and are designed to be **idempotent** (re-runs must be safe). Maintain these properties on edits.

- `bootstrap-ec2-wordpress.sh` runs as **root** on a fresh Ubuntu 24.04 host. Once per EC2.
- `create-site.sh` runs as **root**, reads `RDS_MASTER_PASS` from env (kept out of shell history), generates the per-site DB password and writes it to `/home/ubuntu/webapps/<site>/.credentials` (mode 600, ubuntu only). Once per site.
- `backup-site.sh` runs as **ubuntu** (via cron), uses the EC2 instance IAM role for S3 — no AWS keys in script or env.

When editing a script, syntax-check it before declaring done:

```bash
bash -n bash-scripts/<script>.sh        # syntax check
shellcheck bash-scripts/<script>.sh     # lint (if installed)
```

There are no automated tests in this repo. Real validation happens on a live EC2.

## Common ops reference (these run on the deployed EC2, not here)

| Task | Command |
|---|---|
| Install toolchain on a fresh EC2 | `curl -fsSL https://raw.githubusercontent.com/codetot-web/runcloud-bash-scripts/main/install-tools.sh \| sudo bash` |
| Provision EC2 base | `sudo ct-bootstrap` |
| Create a site | `sudo RDS_MASTER_PASS='xxx' ct-create-site --site=NAME --domain=DOMAIN --git-repo=URL --rds-host=ENDPOINT` |
| Re-apply permissions after git pull | `sudo ct-fix-perm --site=NAME` |
| Manual backup | `ct-backup --site=NAME --bucket=your-backups-prod` |
| Verify DB SSL is active | `sudo -u ubuntu wp db cli -e "SHOW STATUS LIKE 'Ssl_cipher';"` (non-empty = good) |

## Doc/script naming inconsistencies to fix when convenient

The brief flags these as known cleanups (documentation only — won't break anything):
- `bootstrap-ec2-wordpress.sh` still has a `FIX_PERM_URL` env-var step (now redundant — `install-tools.sh` handles it). Drop.
- References to `fix-permission-site` and `backup-site` long names should become `ct-fix-perm` and `ct-backup` (matches installed names).
- `BACKUP-SETUP.md` Phase G.2 says `sudo fix-permission-site` — should be `sudo ct-fix-perm`.
