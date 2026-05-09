# Plan — step-by-step validation of `create-site.sh`

Tracks issue [#1](https://github.com/codetot-web/ec2/issues/1). Branch: `feat/1-validate-create-site`.

## Why

`bash-scripts/create-site.sh` scaffolds a full WordPress site (dirs, git clone, RDS DB, vhost, FPM pool, wp-config). Before using it on a production EC2, validate each `step_*` against the same disposable Ubuntu 24.04 host used for bootstrap validation (`sg10.codetot.org`).

## Validation host

`sg10.codetot.org` — Ubuntu 24.04 VPS with bootstrap already applied. Not a real EC2, so:
- No RDS available → used local MySQL 8.0 with `--local-db` flag
- No `install-tools.sh` → `ct-fix-perm` absent; inline fallback triggered

Site: `masanconsumer`, domain: `msc.codetot.org`  
Git repo: `git@github.com-masanconsumer:codetot-clients/masanconsumer.git`

## Phase 1 — step-by-step validation (run 2026-05-09)

| # | Step | Expected post-condition | Actual | Notes |
|---|------|------------------------|--------|-------|
| 1 | `step_create_dirs` | `/home/ubuntu/webapps/masanconsumer/{public,logs,backups,tmp}` — 2775 ubuntu:www-data | ✓ | |
| 2 | `step_clone_repo` | Repo cloned to `public/` as ubuntu | ✓ | Repo uses `master` branch, not `main` — pass `--git-branch=master` |
| 3 | `step_create_database` | DB + user created, app user can connect | ✓ | Local MySQL, `--local-db` flag; SSL skipped with warn |
| 4 | `step_credentials_file` | `.credentials` mode 600 ubuntu:ubuntu | ✓ | |
| 5 | `step_wp_config` | `wp-config.php` 640 ubuntu:www-data, correct DB + proxy + URL constants | ✓ | `MYSQL_CLIENT_FLAGS` omitted in `--local-db` mode |
| 6 | `step_apache_vhost` | Vhost enabled, `apachectl configtest` clean | ✓ | |
| 7 | `step_php_fpm_pool` | Pool at `/etc/php/8.3/fpm/pool.d/masanconsumer.conf` | ✓ | |
| 8 | `step_reload_services` | Both services reload cleanly | ✓ | |
| 9 | `step_fix_permissions` | Inline fallback (no `ct-fix-perm`) | ✓ | Expected on hosts without `install-tools.sh` |
| 10 | `step_summary` | All values populated, SSL line reflects local mode | ✓ | |

### Findings patched during validation

| Finding | Resolution |
|---------|-----------|
| No way to skip RDS SSL for local dev/test | Added `--local-db` flag: skips `REQUIRE SSL` on user, omits `MYSQL_CLIENT_FLAGS` in wp-config, shows warning |
| `step_summary` hardcoded SSL line regardless of mode | Fixed to branch on `LOCAL_DB` |

### Post-scaffold migration steps (run against sg10)

- **DB**: exported from `sg3.codetot.org` via `wp db export`, imported on sg10 via `wp db import`
- **Table prefix**: repo uses `B4y_` not `wp_` — fixed `$table_prefix` in `wp-config.php` after scaffold
- **URL search-replace**: `http://masanconsumer.ztnhh1kbmv-oy4wrkng23pw.p.temp-site.link` → `https://msc.codetot.org` across all tables
- **Uploads**: 14 GB rsynced directly sg3→sg10 (`runcloud@sg3` → `ubuntu@sg10`)

### Known gap: table prefix

`create-site.sh` always writes `$table_prefix = 'wp_'` in `wp-config.php`. If the imported DB uses a different prefix, the operator must patch it manually. Consider adding a `--table-prefix=PREFIX` flag in a follow-up.

## Phase 2 — idempotency re-run

Pending (blocked until uploads rsync completes and permissions are re-applied).

## What this plan deliberately does not do

- Does not test against real RDS — that is a production validation concern.
- Does not test `ct-fix-perm` — needs `install-tools.sh` installed first.
