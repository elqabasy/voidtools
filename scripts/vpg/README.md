# VPG

VPG (Void PostgreSQL) is a secure backup and disaster-recovery CLI for
PostgreSQL containers. It creates portable logical cluster backups, verifies
them before completion, and performs guarded full-cluster restores.

## Features

- One CLI for backup, restore, verification, and discovery
- Per-database PostgreSQL custom-format dumps plus cluster globals
- SHA-256 file inventory and optional `.tar.gz` archive checksum
- Safe credential input through environment, dotenv, file, or stdin
- Read-only sessions during backup
- Archive path-traversal and symlink protection
- Destructive restore confirmation and preflight verification
- Network-isolated restore container
- Target container remains stopped after a failed destructive restore

VPG performs logical backups. It is suitable for disaster recovery and
migration, but it is not a point-in-time recovery or physical replication
solution.

## Requirements

- Linux with Bash 4.3 or newer
- Docker Engine and permission to manage the target container
- GNU core utilities (`awk`, `base64`, `find`, `sha256sum`, `sort`, `tar`)
- An official-Postgres-compatible container image containing `psql`,
  `pg_dump`, `pg_dumpall`, `pg_restore`, and `pg_isready`

The PostgreSQL client tools in the source container must be compatible with
its server. Restore supports the same or a newer PostgreSQL major version; test
major-version upgrades separately before relying on them in production.

## Install

```bash
cd scripts/vpg
sudo ./install.sh
vpg --help
```

After install, read the manual page with:

```bash
man vpg
```

Use another prefix if needed:

```bash
./install.sh --prefix "$HOME/.local"
```

Ensure `$HOME/.local/bin` is on `PATH`. To uninstall:

```bash
sudo ./install.sh --uninstall
```

VPG can also run directly from the repository:

```bash
./scripts/vpg/vpg --help
```

## Quick start

Create a backup:

```bash
vpg backup /srv/backups/postgres --container infra_postgres --archive
```

List and verify backups:

```bash
vpg list /srv/backups/postgres
vpg verify /srv/backups/postgres/postgres_cluster_2026-08-16_17-30-00_UTC_abcd1234
vpg verify /srv/backups/postgres/postgres_cluster_2026-08-16_17-30-00_UTC_abcd1234.tar.gz
```

Restore after testing the procedure in a non-production environment:

```bash
vpg restore /srv/backups/postgres/postgres_cluster_2026-08-16_17-30-00_UTC_abcd1234.tar.gz \
  --container infra_postgres
```

VPG verifies the complete backup before displaying the destructive
confirmation. Type `REPLACE` to proceed. Automation must explicitly pass
`--force`.

## Credentials and configuration

Configuration precedence is:

1. CLI options
2. Current process environment
3. Dotenv file
4. Built-in defaults

By default, backup reads `./.env` when it exists. Use another file with
`--env-file`.

Supported values:

```dotenv
POSTGRES_USER=postgres
POSTGRES_PASSWORD=
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DB=postgres
BACKUP_COMPRESSION=6
BACKUP_CREATE_ARCHIVE=false
BACKUP_INCLUDE_ROLE_PASSWORDS=false
BACKUP_INCLUDE_TABLESPACES=false
```

Avoid `--password` because command arguments can be exposed through shell
history and process inspection. Prefer:

```bash
vpg backup /srv/backups/postgres \
  --container infra_postgres \
  --username backup_user \
  --password-file /run/secrets/postgres_backup_password
```

Or:

```bash
printf '%s\n' "$POSTGRES_BACKUP_PASSWORD" |
  vpg backup /srv/backups/postgres \
    --container infra_postgres \
    --username backup_user \
    --password-stdin
```

The backup role needs permission to read every database and cluster metadata.
In many installations, a dedicated role with `pg_read_all_data` plus the
required metadata access is preferable to using a superuser. Validate the
result with a complete restore drill.

Role password hashes and tablespace definitions are excluded by default.
Enable them only when the recovery plan requires them:

```bash
vpg backup /srv/backups/postgres \
  --include-role-passwords \
  --include-tablespaces
```

Backups containing role password hashes must be handled as secrets.

## Backup format

Each completed backup directory contains:

- `manifest.txt`: backup metadata and format version
- `globals.sql`: roles and optionally tablespaces
- `database-map.tsv`: safe mapping from dump files to Base64 database names
- `database_NNNN.dump`: one custom-format dump per database
- `FILES.txt`: exact protected-file inventory
- `SHA256SUMS`: checksums for inventory files
- `BACKUP_COMPLETE`: completion marker

Backups are first written to a private `.incomplete` directory. The final
directory name is published only after dumps, structure, inventory, and
checksums pass validation. Failed work is preserved with `BACKUP_FAILED` for
diagnosis and is never accepted by `vpg verify` or `vpg restore`.

`--archive` keeps the directory and also creates a `.tar.gz` file with a
`.sha256` sidecar.

## Restore safety

Restore is intentionally destructive. Before changing the target, VPG:

- validates the bundle format and completion state
- compares the inventory with actual files
- validates every SHA-256 checksum
- validates every database map entry
- checks Docker, the target image, PGDATA, and PostgreSQL versions

After confirmation, VPG stops the target and clears its PGDATA volume. It
restores into a temporary container with networking disabled, verifies the
database count, then starts the original target container.

If a failure occurs after PGDATA is cleared, the target remains stopped. Use
`--keep-failed` to retain the isolated restore container for investigation.

Important operational rules:

1. Keep at least one copy outside the Docker host.
2. Test restores on a schedule; a backup is not proven until restored.
3. Monitor backup exit status and available disk space.
4. Encrypt backups at rest with infrastructure-managed encryption.
5. Retain the VPG version and container image used by each recovery plan.

## Command reference

```text
vpg backup <output-directory> [options]
vpg restore <backup-directory|archive.tar.gz> [options]
vpg verify <backup-directory|archive.tar.gz>
vpg list [backup-directory]
vpg help [command]
vpg version
```

Run `vpg help backup` or `vpg help restore` for all command options.

## Scheduling example

Use a scheduler that records and alerts on the exit status:

```cron
15 2 * * * /usr/local/bin/vpg backup /srv/backups/postgres --container infra_postgres --archive >>/var/log/vpg.log 2>&1
```

Add retention only after confirming its path cannot match unrelated files.
VPG intentionally does not delete backups automatically.

## Development checks

Validate the CLI without a live PostgreSQL container:

```bash
bash scripts/vpg/tests/test_cli.sh
```

This verifies help/version routing, backup listing, directory verification,
archive verification, and checksum failure detection.

