# Weekly Backup Setup — `backup-site.sh`

End-to-end setup for automated weekly WordPress backups to S3. Covers S3 bucket configuration, IAM permissions, AWS CLI install, script installation, cron scheduling, verification, and restore procedures.

**One important clarification up front:** `rsync` doesn't talk to S3 natively. The script uses `aws s3 sync` instead — same incremental-only behaviour (compares size + mtime, uploads only changed/new files), just over the S3 API. For the database, since dumps are monolithic and change entirely each run, the script uploads timestamped `.sql.gz` files and lets S3 lifecycle policy handle retention.

---

## Backup strategy at a glance

| Component | Tool | Frequency suggestion | Cloud storage |
|---|---|---|---|
| Database | `wp db export` + gzip + `aws s3 cp` (timestamped) | Weekly minimum, daily preferred | S3 with lifecycle: STANDARD_IA → GLACIER_IR after 30d → expire after 365d |
| Uploads | `aws s3 sync` (incremental) | Weekly | S3 with versioning ON, STANDARD_IA |
| Code | Git (already covered) | Every commit | GitHub |

This script handles DB + uploads. Code is not backed up here — it lives in GitHub, which is the source of truth.

---

## Phase A — S3 bucket setup (one-time)

Create one bucket per environment, e.g. `codetot-backups-prod`. Region should match the EC2 region for fast intra-region transfer (free vs. cross-region egress).

### A.1 Create bucket with versioning + encryption

```bash
# From any machine with AWS CLI configured (your laptop, Cloud Shell, etc.)
aws s3api create-bucket \
    --bucket codetot-backups-prod \
    --region ap-southeast-1 \
    --create-bucket-configuration LocationConstraint=ap-southeast-1

# Versioning ON — protects against ransomware + accidental deletion
aws s3api put-bucket-versioning \
    --bucket codetot-backups-prod \
    --versioning-configuration Status=Enabled

# Default encryption (SSE-S3, free)
aws s3api put-bucket-encryption \
    --bucket codetot-backups-prod \
    --server-side-encryption-configuration '{
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    }'

# Block all public access — these are private backups
aws s3api put-public-access-block \
    --bucket codetot-backups-prod \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### A.2 Lifecycle policy

Save this as `lifecycle.json`:

```json
{
  "Rules": [
    {
      "Id": "db-dumps-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "backups/" },
      "Transitions": [
        { "Days": 30, "StorageClass": "GLACIER_IR" }
      ],
      "Expiration": { "Days": 365 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }
    },
    {
      "Id": "abort-incomplete-multipart",
      "Status": "Enabled",
      "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

Apply:

```bash
aws s3api put-bucket-lifecycle-configuration \
    --bucket codetot-backups-prod \
    --lifecycle-configuration file://lifecycle.json
```

What this does:
- DB dumps and uploads stay in `STANDARD_IA` for 30 days (cheap to retrieve when fresh)
- After 30 days, transition to `GLACIER_IR` (~70% cheaper, retrieve in milliseconds)
- After 365 days, delete entirely
- Old versions (from sync overwrites) expire after 30 days
- Failed multipart uploads are auto-cleaned after 7 days (saves money)

If you want longer retention for compliance, change `Expiration.Days` to e.g. `2555` (7 years) and add a transition to `DEEP_ARCHIVE` at day 90.

---

## Phase B — IAM role (one-time per EC2)

The EC2 instance role needs S3 read/write on the backup bucket. This was sketched in the bootstrap script's IAM requirements; here's the actual policy.

### B.1 Policy JSON

Save as `s3-backup-policy.json` and replace the bucket name:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::codetot-backups-prod"
    },
    {
      "Sid": "ReadWriteObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:GetObjectVersion",
        "s3:ListBucketVersions"
      ],
      "Resource": "arn:aws:s3:::codetot-backups-prod/*"
    }
  ]
}
```

### B.2 Attach to the EC2 instance role

```bash
# Create the policy
aws iam create-policy \
    --policy-name CodetotBackupS3Access \
    --policy-document file://s3-backup-policy.json

# Attach to the EC2 instance role (replace ROLE_NAME with your actual role)
aws iam attach-role-policy \
    --role-name <YOUR_EC2_INSTANCE_ROLE_NAME> \
    --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/CodetotBackupS3Access
```

If the EC2 instance has no IAM role yet, create one and associate it with the instance — that's a separate AWS Console / CLI workflow.

### B.3 Verify from EC2

```bash
# SSH into EC2 as ubuntu
aws sts get-caller-identity
# Should return the role ARN, not an IAM user ARN.

aws s3 ls s3://codetot-backups-prod/
# Should succeed (empty list is fine).

echo "test" | aws s3 cp - s3://codetot-backups-prod/connectivity-test.txt
aws s3 rm s3://codetot-backups-prod/connectivity-test.txt
# Both must succeed before proceeding.
```

---

## Phase C — Install AWS CLI v2 on EC2

The Ubuntu apt package `awscli` is v1 (older, slower, fewer features). Install v2 directly:

```bash
# On EC2 as ubuntu
cd /tmp

# x86_64 (most t3 / m5 / c5 instances)
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip

# ARM (Graviton / t4g / c7g instances) — use this URL instead:
# curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o awscliv2.zip

unzip -q awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/

aws --version
# Expected: aws-cli/2.x.x ...
```

Set the default region (so you don't need `--region` on every command):

```bash
sudo -u ubuntu aws configure set region ap-southeast-1
```

---

## Phase D — Install backup-site.sh

```bash
# On EC2 as ubuntu — host the script in your repo first, then:
sudo wget -q https://raw.githubusercontent.com/codetot-web/runcloud-bash-scripts/main/backup-site.sh \
    -O /usr/local/bin/backup-site
sudo chmod +x /usr/local/bin/backup-site

# Verify
backup-site --help
```

### Test run (manual, before scheduling)

```bash
backup-site --site=masanconsumer --bucket=codetot-backups-prod
```

You should see timestamped log output ending with the latest 3 DB backups in S3. If anything fails, the script aborts loudly — common failure modes:

- `AWS credentials not working` → IAM role not attached, or `aws sts get-caller-identity` fails (Phase B issue).
- `wp db export failed` → DB credentials in `wp-config.php` wrong, or RDS unreachable from this EC2.
- `Site not found: /home/ubuntu/webapps/.../public` → wrong `--site` value.

---

## Phase E — Schedule with cron (weekly)

The script runs as the **ubuntu** user — no sudo needed (uses instance IAM role for AWS, and ubuntu has read access to all site files via group membership).

### E.1 Edit ubuntu's crontab

```bash
crontab -e   # as ubuntu, NOT root
```

Add these lines (all times are local — set at `bootstrap` time via `timedatectl`):

```cron
# === WordPress backups ===
# Email cron failures (set MAILTO if you have an MTA configured, e.g. via SES)
# MAILTO=ops@codetot.com

# Log directory (one log per site, rotated by logrotate — see E.3)
BACKUP_LOG_DIR=/home/ubuntu/webapps

# masanconsumer — Sunday 02:00 local time (= staggered, low traffic)
0 2 * * 0 /usr/local/bin/backup-site --site=masanconsumer --bucket=codetot-backups-prod >> $BACKUP_LOG_DIR/masanconsumer/logs/backup.log 2>&1

# Add more sites here, staggered 30+ minutes apart so they don't compete for resources:
# 30 2 * * 0 /usr/local/bin/backup-site --site=othersite --bucket=codetot-backups-prod >> $BACKUP_LOG_DIR/othersite/logs/backup.log 2>&1
```

### E.2 Verify the cron entry

```bash
crontab -l
```

### E.3 Logrotate (so backup.log doesn't grow forever)

```bash
sudo tee /etc/logrotate.d/wp-backup > /dev/null <<'EOF'
/home/ubuntu/webapps/*/logs/backup.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    su ubuntu www-data
    create 0664 ubuntu www-data
}
EOF
```

12 weeks of backup logs is plenty for debugging and auditing.

### E.4 Daily DB-only schedule (recommended add-on)

Weekly is the minimum. For production, add a daily DB-only backup — uploads can stay weekly because they change less often:

```cron
# Daily DB-only backup at 03:00 (skip uploads)
0 3 * * 1-6 /usr/local/bin/backup-site --site=masanconsumer --bucket=codetot-backups-prod --skip-uploads >> $BACKUP_LOG_DIR/masanconsumer/logs/backup.log 2>&1
```

`1-6` = Mon–Sat, so Sunday's full weekly backup isn't doubled.

---

## Phase F — Verification

### F.1 First-run sanity checks (after one week)

```bash
# Latest DB backup
aws s3 ls s3://codetot-backups-prod/backups/masanconsumer/db/ | sort | tail -5

# Uploads sync — compare object count
aws s3 ls s3://codetot-backups-prod/backups/masanconsumer/uploads/ --recursive | wc -l
find /home/ubuntu/webapps/masanconsumer/public/wp-content/uploads -type f | wc -l
# Numbers should be very close (S3 may have a few extra from file deletions
# preserved by versioning).

# Local backups directory
ls -lah /home/ubuntu/webapps/masanconsumer/backups/

# Last cron log lines
tail -50 /home/ubuntu/webapps/masanconsumer/logs/backup.log
```

### F.2 CloudWatch alarm — alert on missing backups

If a weekly cron job silently dies (server reboots during backup window, IAM permissions change, etc.) you want to know fast. Set a CloudWatch alarm on the most-recent-object age:

This isn't built into S3 directly — easiest is a small Lambda on a daily schedule that checks the latest object's `LastModified` and publishes a custom metric. Implementation is outside this script's scope, but the pattern is:

1. Lambda runs daily at 04:00.
2. Lists `backups/<site>/db/` sorted by date.
3. Computes age of newest object in days.
4. Puts custom metric `BackupAge` to CloudWatch.
5. CloudWatch alarm: `BackupAge > 8 days` → SNS → email/Slack.

Quick alternative without Lambda — a daily cron on EC2 itself:

```bash
# Add to ubuntu's crontab — alerts if no DB backup in last 8 days
0 4 * * * /usr/local/bin/backup-age-check --site=masanconsumer --bucket=codetot-backups-prod --max-age-days=8 || echo "STALE BACKUP" | mail -s "Backup alert: masanconsumer" ops@codetot.com
```

(That `backup-age-check` helper isn't in this drop — let me know if you want it.)

---

## Phase G — Restore procedure

This is the part most teams never test. Test it. At least once. Ideally to a staging EC2 so you don't risk production.

### G.1 Restore database

```bash
# As ubuntu, on the target EC2 (could be sg3.codetot.org for staging restore)

# 1. List available DB backups
aws s3 ls s3://codetot-backups-prod/backups/masanconsumer/db/ | sort

# 2. Pick the dump you want and download it
aws s3 cp s3://codetot-backups-prod/backups/masanconsumer/db/db-2026-05-04T19-00-00Z.sql.gz \
    /tmp/restore.sql.gz

# 3. Restore (DESTRUCTIVE — drops existing tables via --add-drop-table in dump)
cd /home/ubuntu/webapps/masanconsumer/public
gunzip -c /tmp/restore.sql.gz | wp db import -

# 4. Flush caches
wp cache flush
wp rewrite flush

# 5. Clean up
rm /tmp/restore.sql.gz
```

### G.2 Restore uploads

```bash
# Pull S3 → local. Uses sync, so re-running is safe and incremental.
aws s3 sync s3://codetot-backups-prod/backups/masanconsumer/uploads/ \
            /home/ubuntu/webapps/masanconsumer/public/wp-content/uploads/

# Re-apply permissions
sudo fix-permission-site --site=masanconsumer
```

### G.3 Restore a specific deleted file from S3 versioning

If someone accidentally deleted an uploaded file and the latest sync already propagated the deletion (it shouldn't — `--delete` is OFF — but just in case):

```bash
# List versions of the lost file
aws s3api list-object-versions \
    --bucket codetot-backups-prod \
    --prefix backups/masanconsumer/uploads/2024/03/important-photo.jpg

# Download a specific version by VersionId
aws s3api get-object \
    --bucket codetot-backups-prod \
    --key backups/masanconsumer/uploads/2024/03/important-photo.jpg \
    --version-id <VERSION_ID> \
    /tmp/important-photo.jpg
```

### G.4 Point-in-time DB restore (via RDS, not this script)

Note that this script does NOT replace RDS automated backups. RDS handles point-in-time recovery (PITR) with 7-day retention by default. For "restore to 14:23 yesterday" scenarios, use RDS PITR. This script is for:

- Disaster recovery if RDS is destroyed entirely
- Cross-region/cross-account safety net
- Long-term retention beyond RDS's default 7 days
- Consistent dumps that include uploads in the same recovery point

---

## Phase H — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `AWS credentials not working` | Instance role not attached, or wrong region | `aws sts get-caller-identity`; check EC2 console → instance → IAM role |
| `Access Denied` on `s3:PutObject` | IAM policy missing or bucket name mismatch | Re-check Phase B.1 policy + actual bucket ARN |
| `wp db export failed` | DB credentials wrong in wp-config, or RDS unreachable | `wp db check`; verify SG `sg-rds` allows `sg-ec2` |
| Backup runs but log shows partial uploads | EC2 ran out of disk during dump | Increase `/home/ubuntu/webapps/<site>/backups` space, or set `--retention-days=1` |
| Cron doesn't fire at all | Cron is disabled, or wrong user's crontab | `systemctl status cron`; `crontab -l` (as ubuntu, not root) |
| Lock file persists after kill | Previous run died without releasing flock | `rm /tmp/wp-backup-<site>.lock` |
| S3 sync extremely slow | Many tiny files in uploads/ | Normal — listing is the slow part. Consider `--size-only` (faster but misses content edits with same byte count) |

---

## Reference — full toolchain

| Script | Run by | Frequency | Purpose |
|---|---|---|---|
| `bootstrap-ec2-wordpress.sh` | root | Once per EC2 | OS + Apache + PHP + WP-CLI + RDS CA + users + firewall |
| `create-site.sh` | root | Once per site | Dirs + repo + DB + vhost + pool + wp-config + permissions |
| `fix-permission-site.sh` | root | After file changes | Re-apply ubuntu:www-data perms, lock `.git`, refresh ACLs |
| `backup-site.sh` | ubuntu (via cron) | Weekly + optional daily | DB dump + uploads sync to S3 |
