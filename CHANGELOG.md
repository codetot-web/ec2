# Changelog

All notable changes to this repo are tracked here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [SemVer](https://semver.org/) for the bash toolchain (the
`PROJECT-BRIEF.md` and runbooks are versioned alongside the scripts).

## [0.1.0] — 2026-05-09

Inaugural public release.

### Added

- `bootstrap-ec2-wordpress.sh` — provisions a fresh Ubuntu 24.04 host
  with Apache (mpm_event) + PHP 8.3-FPM + WP-CLI + Redis + RDS CA bundle
  + ufw + fail2ban + 2 GB swap. Idempotent; safe to re-run.
- `create-site.sh` — scaffolds one site (dirs, optional git clone, RDS
  DB+user, vhost, FPM pool, wp-config.php, permissions).
- `backup-site.sh` — DB dump + uploads sync to S3 via instance IAM role.
- `BACKUP-SETUP.md` — operational runbook for the S3 backup pipeline.
- `PROJECT-BRIEF.md` — architecture, locked-in decisions, anti-patterns.
- `plans/bootstrap-validation.md` — step-by-step validation log against
  a fresh Ubuntu 24.04 VPS, including the EC2-equivalent `ubuntu`-user
  setup needed for non-EC2 validation hosts.
- `CLAUDE.md` — guidance for Claude Code sessions in this repo.

### Notes

- The `ct-` command prefix is just a short tag for the installed-on-EC2
  helper commands. Rename if it doesn't suit your team.
- The toolchain installer (`install-tools.sh`) is referenced in the
  brief but not yet committed here — it's expected to live alongside
  the install URL pointed at by the `Quick start` section of
  `PROJECT-BRIEF.md`.
- This release rolls together five idempotency + observability fixes
  to `bootstrap-ec2-wordpress.sh` that were validated end-to-end on a
  disposable Ubuntu 24.04 VPS:
  - `step_swap` detects any active swap, not just `/swapfile`, so
    vendor-provisioned swap partitions don't trigger redundant swap.
  - `step_install_wp_cli` skips the phar download when a working `wp`
    is already on `PATH`.
  - `step_rds_ca_bundle` skips download when the bundle already exists
    and parses as valid x509.
  - `step_summary` lists every active swap with its size, not just the
    first row.
  - `step_summary` warns loudly with the pending package list when
    `/var/run/reboot-required` exists after `apt full-upgrade`.

[0.1.0]: https://github.com/codetot-web/ec2/releases/tag/v0.1.0
