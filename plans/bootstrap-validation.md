# Plan — step-by-step validation of `bootstrap-ec2-wordpress.sh`

Reference walk-through for validating the bootstrap script against a disposable Ubuntu 24.04 host before running it for real.

## Why

`bash-scripts/bootstrap-ec2-wordpress.sh` was written for a fresh Ubuntu 24.04 EC2 AMI. Before the first production cutover, step through each `step_*` against a disposable host to catch latent assumptions (PPA gaps, swap path collisions, ufw ordering, redis startup mode, `ubuntu`-user dependence) before they show up in production.

## Validation host

`validator.example.com` — fresh Ubuntu 24.04.4 LTS VPS, x86_64, 7.8 GB RAM, 99 GB disk. No web stack pre-installed (only `mysql-common`).

Local creds in repo-root `.env` (gitignored):

```
SSH_ACCESS=ubuntu@validator.example.com
SSH_PASSWORD=<see .env>
```

## Phase 0 — host pre-prep (DONE)

EC2 ships with a `ubuntu` user that has passwordless sudo. This VPS started root-only, so we synthesised that environment:

```bash
useradd -m -s /bin/bash -c "EC2-equivalent admin user" ubuntu
echo "ubuntu:<password>" | chpasswd
usermod -aG sudo ubuntu
cat >/etc/sudoers.d/90-ubuntu-nopasswd <<'SUDO'
ubuntu ALL=(ALL) NOPASSWD:ALL
SUDO
chmod 0440 /etc/sudoers.d/90-ubuntu-nopasswd
visudo -cf /etc/sudoers.d/90-ubuntu-nopasswd
```

Verified: `id ubuntu` → uid=1000, sudo group; `sudo -n whoami` → `root`; `.env` rewritten to `ubuntu@validator.example.com`.

**Known cosmetic noise:** `sudo: unable to resolve host localhost.localdomain` on every sudo call. The hostname isn't in `/etc/hosts`. Harmless but noisy — fix optionally with `echo "127.0.1.1 $(hostname)" >> /etc/hosts`.

## Phase 1 — run each `step_*` independently

Run each step from `bash-scripts/bootstrap-ec2-wordpress.sh` in isolation by sourcing the helper functions and invoking just one. Pattern:

```bash
sshpass -p "$SSH_PASSWORD" ssh "$SSH_ACCESS" \
    'sudo bash -c "source /tmp/bootstrap-ec2-wordpress.sh && step_<name>"'
```

(Upload the script to `/tmp/` once at the start; `set -euo pipefail` at the top of the script means the helpers are available to source.)

### Step checklist (run 2026-05-09)

| # | Step | Expected post-condition | Actual | Notes |
|---|------|------------------------|--------|-------|
| 1 | `step_system_update` | apt-get update/full-upgrade/autoremove clean | ✓ | New kernel `6.8.0-111` installed; running kernel still `-101`. Reboot recommended after the full bootstrap. |
| 2 | `step_timezone` | timedatectl Timezone = `Asia/Ho_Chi_Minh` | ✓ | |
| 3 | `step_install_packages` | apache2 + PHP 8.3 + ext + redis + mysql client | ✓ | PHP 8.3.6; all 11 required modules present (`php -m` confirmed). `php-imagick` apt package works on noble — no PPA fallback needed. |
| 4 | `step_configure_apache` | mpm_event + proxy_fcgi + rewrite + headers + expires + deflate + ssl + remoteip + setenvif enabled; no mod_php; 000-default disabled | ✓ | First run also enabled `socache_shmcb` (transitive via `ssl`) — fine. |
| 5 | `step_install_wp_cli` | `/usr/local/bin/wp --info` works | ✓ | WP-CLI 2.12.0. **Note:** re-runs unconditionally re-download the phar — minor inefficiency, not a bug. |
| 6 | `step_rds_ca_bundle` | bundle at `/etc/ssl/certs/rds-global-bundle.pem`, root:root 644, parses | ✓ | 108 certs, 165 KB. |
| 7 | `step_users_and_permissions` | ubuntu in www-data group + vice versa; umask 002 in `.bashrc`/`.profile`; git safe.directory set | ✓ | Pre-created `ubuntu` user merged cleanly. |
| 8 | `step_webapps_dir` | `/home/ubuntu/webapps` ubuntu:www-data 2755 | ✓ | |
| 9 | `step_swap` | `/swapfile` 2G + vm.swappiness=10 + fstab entry | ✓ | **Finding:** VPS shipped with a pre-existing 128 MB `/dev/vdb` swap partition. Script added a separate `/swapfile` 2G — both active, kernel uses both. Not a bug; worth flagging. |
| 10 | `step_firewall` | ufw active, 22/80/443 allowed, default deny incoming | ✓ | Confirmed SSH port = 22 before enabling. |
| 11 | `step_fail2ban` | `systemctl is-active fail2ban` = active | ✓ | sshd jail loaded. |
| 12 | `step_redis` | `redis-cli ping` = PONG | ✓ | |
| 13 | `step_fix_perm_script` | Skipped (FIX_PERM_URL unset) | ✓ (skipped as designed) | Step slated for removal — `install-tools.sh` will replace it. Tracked in PROJECT-BRIEF cleanup list. |
| 14 | `step_summary` | All values populated | ✓ | **Finding:** swap row uses `swapon --show --noheadings \| head -1`, which only prints `/dev/vdb` (the first one), hiding the script's own `/swapfile`. Cosmetic. |

### Idempotency re-run — ✓

Re-running `sudo bash /tmp/bootstrap-ec2-wordpress.sh` end-to-end produced no destructive deltas:

- apt: nothing to install/upgrade
- Apache modules: all already enabled
- WP-CLI: re-downloaded (no version check) — same 2.12.0
- RDS CA: re-downloaded (no `-N`/conditional flag)
- ufw/fail2ban/redis: all reported already active
- Swap: `Swap already active` (idempotency check works)

### Findings to consider patching

Severity: all minor. None block the acmeshop cutover.

1. **Pre-existing swap partition not detected.** `step_swap` checks for `/swapfile` only. On hosts with a vendor-provisioned swap partition (e.g. this VPS's `/dev/vdb`), we end up with two swaps. EC2 AMIs don't ship swap, so this won't bite there — but the script could be friendlier with a generic `swapon --show \| grep -q .` guard.
2. **`step_install_wp_cli` re-downloads on every run.** Wastes ~7 MB and a few seconds. Easy guard: skip download if `wp --info` already reports a version.
3. **`step_rds_ca_bundle` always re-downloads.** Same fix pattern. Use `wget -N` or check existence first.
4. **`step_summary` swap row truncated.** `swapon --show --noheadings 2>/dev/null \| head -1` should be `tr '\n' ' '` or drop `head -1`.
5. **No reboot prompt after kernel upgrade.** apt installed a new kernel during step 1 but the script doesn't surface this. Could add a final-line check on `/var/run/reboot-required`.

These warrant a follow-up patch PR — not blocking #1 closure if we decide they're trivial.

### Idempotency re-run

After step 14 passes, re-run **the entire script** (`sudo bash bootstrap-ec2-wordpress.sh`). Expectation: every step prints `✓` with no destructive deltas (no fresh apt installs, no duplicate sudoers entries, no new swapfile creation).

## Phase 2 — record divergences (DONE)

The five "Findings to consider patching" items above were all addressed in v0.1.0:

| Finding | Resolution |
|---|---|
| Pre-existing swap partition not detected | `step_swap` now checks for any active swap |
| `step_install_wp_cli` re-downloads on every run | Skip when `wp` works |
| `step_rds_ca_bundle` always re-downloads | Skip when bundle parses |
| `step_summary` swap row truncated | List every active swap with size |
| No reboot prompt after kernel upgrade | Warn via `/var/run/reboot-required` |

## Phase 3 — gate (DONE)

1. ✓ All 14 step rows show ✓.
2. ✓ Idempotent re-run produces no destructive state changes.
3. ✓ Patches included in v0.1.0.

## What this plan deliberately does not do

- It does not call `create-site.sh` or `backup-site.sh` against the host. Those are separate issues — they depend on bootstrap passing first and on RDS being available.
- It does not destroy/reset the VPS between runs. We're testing idempotency, not from-scratch reproducibility. If the host gets into a weird state, the user can re-image; we don't try to reverse-engineer cleanup.
