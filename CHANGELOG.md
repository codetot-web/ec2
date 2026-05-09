# Changelog

All notable changes to this repo are tracked here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [SemVer](https://semver.org/) for the bash toolchain (the
`PROJECT-BRIEF.md` and runbooks are versioned alongside the scripts).

## [0.1.0] — 2026-05-09

Inaugural tagged release. Captures the initial workspace import plus the
first round of bootstrap script hotfixes validated against
`sg10.codetot.org`.

### Added

- `bootstrap-ec2-wordpress.sh` — provisions a fresh Ubuntu 24.04 host
  with Apache (mpm_event) + PHP 8.3-FPM + WP-CLI + Redis + RDS CA bundle
  + ufw + fail2ban + 2 GB swap.
- `create-site.sh` — scaffolds one site (dirs, optional git clone, RDS
  DB+user, vhost, FPM pool, wp-config.php, permissions).
- `backup-site.sh` — DB dump + uploads sync to S3 via instance IAM role.
- `BACKUP-SETUP.md` — operational runbook for the S3 backup pipeline.
- `PROJECT-BRIEF.md` — consolidated context for any agent continuing
  this work (architecture, locked-in decisions, anti-patterns).
- `CLAUDE.md` — guidance for Claude Code sessions in this repo.
- `plans/bootstrap-validation.md` — step-by-step validation log against
  `sg10.codetot.org` for issue #1.

### Fixed

Bootstrap hotfixes from issues #2-6, validated end-to-end on the
validation host:

- `step_swap` (#2): detect any active swap, not just `/swapfile`, so
  vendor-provisioned swap partitions don't trigger a redundant
  `/swapfile` on top.
- `step_install_wp_cli` (#3): skip the phar download when a working
  `wp` is already on `PATH` (saves ~7 MB per re-run).
- `step_rds_ca_bundle` (#4): skip the bundle download when the file
  exists and parses as valid x509.
- `step_summary` (#5): list every active swap with its size instead of
  truncating to the first row.
- `step_summary` (#6): warn loudly with the pending package list when
  `/var/run/reboot-required` exists after `apt full-upgrade`.

[0.1.0]: https://github.com/codetot-workspace/ec2/releases/tag/v0.1.0
