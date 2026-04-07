# storage

**Last Updated:** 2026-01-14

Manage Backblaze B2 cloud storage for backups and podcast media.

## Overview

The `storage` command provides an interface for managing Backblaze B2 cloud storage, including bucket management, file uploads/downloads, authentication, and application key management. It's used for storing backups and podcast media files.

## Synopsis

```bash
pl storage <command> [options]
```

## Commands

| Command | Description |
|---------|-------------|
| `auth` | Authenticate with B2 |
| `list` | List all buckets |
| `info <bucket>` | Show bucket details |
| `files <bucket> [prefix]` | List files in bucket |
| `upload <file> <bucket> [remote_name]` | Upload file to bucket |
| `delete <bucket> <file>` | Delete file from bucket |
| `keys` | List application keys |
| `key-delete <key_id>` | Delete an application key |

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `bucket` | Conditional | Bucket name (required for info, files, upload, delete) |
| `file` | Conditional | Local file path (required for upload, delete) |
| `prefix` | No | File prefix filter for listing (optional) |
| `remote_name` | No | Remote filename for upload (defaults to local filename) |
| `key_id` | Yes | Application key ID (required for key-delete) |

## Examples

### Authenticate with Backblaze B2

```bash
pl storage auth
```

Authenticate using credentials from `.secrets.yml`.

### List All Buckets

```bash
pl storage list
```

Display all B2 buckets in the account.

### Show Bucket Details

```bash
pl storage info podcast-media
```

Show details for the `podcast-media` bucket.

### List Files in Bucket

```bash
pl storage files mybackups
```

List all files in the `mybackups` bucket.

### List Files with Prefix

```bash
pl storage files mybackups 2026-01/
```

List only files starting with `2026-01/` in the bucket.

### Upload File to Bucket

```bash
pl storage upload backup.sql.gz mybackups
```

Upload `backup.sql.gz` to the `mybackups` bucket with same filename.

### Upload with Custom Remote Name

```bash
pl storage upload backup.sql.gz mybackups sites/avc/backup-2026-01-14.sql.gz
```

Upload with custom remote path and filename.

### Delete File from Bucket

```bash
pl storage delete mybackups old-backup.sql.gz
```

Delete `old-backup.sql.gz` from the `mybackups` bucket.

### List Application Keys

```bash
pl storage keys
```

Display all B2 application keys for the account.

### Delete Application Key

```bash
pl storage key-delete 0123456789abcdef
```

Delete application key with ID `0123456789abcdef`.

## Configuration

Add B2 credentials to `.secrets.yml`:

```yaml
b2:
  account_id: "your-account-id"
  app_key: "your-application-key"
```

### Getting Credentials

1. Log in to Backblaze B2 console: https://www.backblaze.com/b2/
2. Navigate to "App Keys"
3. Create new application key
4. Copy Account ID and Application Key
5. Add to `.secrets.yml`

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (auth failed, file not found, operation failed) |

## Prerequisites

- Backblaze B2 account
- B2 credentials in `.secrets.yml`
- `b2` command-line tool installed
- Internet connectivity
- Write permissions for local files (upload)

## Installing B2 CLI

```bash
# Ubuntu/Debian
pip3 install b2

# macOS
brew install b2-tools

# Or Python pip
pip install b2
```

## Authentication

### First-Time Setup

```bash
# Authenticate
pl storage auth

# Verify authentication
pl storage list
```

### Authentication Caching

Authentication tokens are cached temporarily. Re-authenticate if:
- Commands return "unauthorized" errors
- Credentials have been rotated
- Token has expired (24 hours)

## Bucket Management

### Public vs Private Buckets

- **Private buckets**: Files require authentication to access
- **Public buckets**: Files accessible via direct URL

### Getting Public URL

```bash
pl storage info podcast-media
```

Output includes:
```
Public URL: https://f123.backblazeb2.com/file/bucket-name/
```

### Bucket Naming

B2 bucket names must:
- Be globally unique
- Contain only letters, numbers, hyphens
- Be 6-50 characters long
- Start and end with letter or number

## File Operations

### Upload Performance

- Files are uploaded with SHA1 verification
- Large files (>100MB) use chunked uploads
- Progress is shown during upload
- Interrupted uploads can be resumed

### File Naming

B2 supports:
- Full path hierarchies (`sites/avc/backups/file.sql.gz`)
- Unicode filenames
- Spaces in names (not recommended)

### File Metadata

Files store metadata:
- Upload timestamp
- SHA1 checksum
- Content type (auto-detected)
- Custom headers (if configured)

## Troubleshooting

### Authentication Fails

**Symptom:** "Authorization failure" error

**Solution:**
1. Verify credentials in `.secrets.yml`
2. Check Account ID is correct (not bucket ID)
3. Ensure Application Key has necessary capabilities
4. Check for whitespace in credentials
5. Regenerate application key if compromised

### Upload Fails with "File Not Found"

**Symptom:** Cannot upload file

**Solution:**
```bash
# Verify file exists
ls -lh backup.sql.gz

# Use absolute path
pl storage upload /full/path/to/backup.sql.gz mybucket

# Check file permissions
chmod 644 backup.sql.gz
```

### Bucket Not Listed

**Symptom:** Expected bucket doesn't appear in list

**Solution:**
1. Verify bucket exists in B2 web console
2. Check application key has bucket access permissions
3. Ensure authenticated with correct account
4. Try re-authenticating: `pl storage auth`

### Delete Fails - File Not Found

**Symptom:** Cannot delete file that appears in listing

**Solution:**
1. Verify exact filename (case-sensitive)
2. Use full path including directories
3. Check for hidden characters: `pl storage files bucket | cat -A`
4. Ensure file isn't in versioned state

### Slow Upload/Download

**Symptom:** File operations are slow

**Solution:**
1. Check internet bandwidth
2. B2 may throttle high-volume transfers
3. Consider using B2 desktop sync client for large transfers
4. Compress files before upload
5. Use regional B2 data centers closer to server

### "Too Many Requests" Error

**Symptom:** Rate limit error

**Solution:**
1. Wait 60 seconds before retrying
2. Reduce concurrent operations
3. Implement exponential backoff in scripts
4. Consider B2 API rate limits (class C: 1000/day)

## Best Practices

### Organize Files with Prefixes

```bash
# Use date-based prefixes
pl storage upload backup.sql.gz mybackups 2026/01/14/backup.sql.gz

# Use site-based prefixes
pl storage upload media.tar.gz mybackups sites/avc/media.tar.gz
```

### Implement Lifecycle Policies

Configure in B2 console:
- Auto-delete files older than 90 days
- Move to cheaper storage tier after 30 days
- Keep last N versions of file

### Secure Credentials

```bash
# .secrets.yml should be readable only by user
chmod 600 .secrets.yml

# Never commit credentials
git ls-files | grep secrets.yml  # Should return nothing
```

### Test Uploads

```bash
# Upload test file
echo "test" > test.txt
pl storage upload test.txt mybucket

# Verify upload
pl storage files mybucket | grep test.txt

# Clean up
pl storage delete mybucket test.txt
```

### Monitor Storage Usage

```bash
# Check bucket info regularly
pl storage info mybucket

# Review total storage in B2 console
# Set up billing alerts
```

## Automation Examples

### Backup to B2

```bash
#!/bin/bash
SITE="mysite"
BUCKET="mybackups"
BACKUP_FILE="backup-$(date +%Y%m%d).sql.gz"

# Create backup
pl backup -b "$SITE" "Daily backup"

# Upload to B2
pl storage upload "sites/$SITE/backups/$BACKUP_FILE" "$BUCKET" "$SITE/$BACKUP_FILE"

echo "Backup uploaded to B2: $BUCKET/$SITE/$BACKUP_FILE"
```

### Clean Old Backups

```bash
#!/bin/bash
BUCKET="mybackups"
SITE="mysite"

# Get files older than 30 days
CUTOFF=$(date -d '30 days ago' +%Y%m%d)

pl storage files "$BUCKET" "$SITE/" | while read line; do
  filename=$(echo "$line" | awk '{print $NF}')
  if [[ "$filename" < "$SITE/backup-${CUTOFF}" ]]; then
    echo "Deleting old backup: $filename"
    pl storage delete "$BUCKET" "$filename"
  fi
done
```

### Sync Local Directory to B2

```bash
#!/bin/bash
LOCAL_DIR="sites/mysite/private"
BUCKET="mysite-private"

# Upload all files in directory
find "$LOCAL_DIR" -type f | while read file; do
  remote_name="${file#$LOCAL_DIR/}"
  pl storage upload "$file" "$BUCKET" "$remote_name"
done
```

## Notes

- Storage uses `lib/b2.sh` library for operations
- Authentication token cached in `~/.b2_account_info`
- File operations are idempotent (safe to retry)
- B2 supports file versioning (keep previous versions)
- Deleted files can be recovered within version retention period
- B2 has no minimum storage time (unlike AWS S3)
- First 10 GB storage per day is free
- Bandwidth charges apply for downloads

## Performance Considerations

- Upload speed limited by internet bandwidth
- B2 automatically uses multi-part uploads for large files
- Download speeds typically faster than upload
- Consider using B2's CDN integration for public files
- Compression reduces storage costs and transfer time

## Security Implications

- Application keys can be restricted to specific buckets
- Use read-only keys for public/download-only access
- Private buckets require authentication for all access
- Files in private buckets generate temporary signed URLs
- Application keys can be time-limited
- Monitor key usage in B2 console
- Rotate keys periodically for security
- Store credentials in `.secrets.yml` (infrastructure secrets only)

## Cost Considerations

### B2 Pricing (as of 2026-01)

- **Storage**: $0.005/GB/month (first 10 GB free)
- **Download**: $0.01/GB (first 1 GB/day free)
- **Upload**: Free
- **API Calls**: Class A (write): $0.004/10k, Class B (read): $0.004/10k, Class C (list): Free

### Cost Optimization

```bash
# Compress before upload
gzip -9 backup.sql
pl storage upload backup.sql.gz mybucket

# Use lifecycle rules to auto-delete old backups
# Set in B2 console under Lifecycle Settings

# Monitor usage
pl storage info mybucket  # Check file count and size
```

## Related Commands

- [backup.sh](backup.md) - Create backups for upload
- [restore.sh](restore.md) - Restore from B2 backups
- [sync.sh](sync.md) - Synchronize directories with B2

## See Also

- [Backblaze B2 Documentation](https://www.backblaze.com/b2/docs/) - Official B2 docs
- [B2 CLI Reference](https://www.backblaze.com/b2/docs/quick_command_line.html) - Command-line tool docs
- [Backup Guide](../../guides/backup-restore.md) - NWP backup strategies
- [Cloud Storage Architecture](../../decisions/0006-cloud-storage.md) - Storage design decisions
- [Cost Optimization Guide](../../guides/cloud-cost-optimization.md) - Reducing storage costs
