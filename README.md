# gutenberg-sync

Automatically mirrors Project Gutenberg's EPUB catalog via rsync and tracks sync state in a local SQLite database. Designed to run as a Docker container on a home server, feeding an ingest folder (e.g. a library manager's).

## What it does

- Syncs `*-images-3.epub` files (the illustrated EPUB variant) from `aleph.gutenberg.org::gutenberg-epub`
- Downloads each filename once: synced filenames are tracked in SQLite, and files deleted from `raw/` (e.g. after ingestion) are never re-downloaded
- Lists the mirror, diffs against the DB locally, and fetches only new files via `--files-from`
- Downloads into `staging/`, records each completed file in the DB, then moves it into `raw/`, so a consumer can take files at any time without causing re-downloads
- Writes files flat into `raw/` (`raw/pg123-images-3.epub`)
- Runs on a 24-hour cycle by default
- Handles rsync failures (completed files are always recorded; hard failures retry after 5 minutes) and shuts down cleanly on `docker stop`, even mid-transfer

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/gutenberg-sync.git
```

Edit `docker-compose.yml` to set your volume paths:

- `/path/to/ebooks/gutenberg` → `/gutenberg`: holds `raw/` (finished EPUBs) and `staging/` (in-progress downloads)
- `/path/to/gutenberg-sync/db` → `/db`: the SQLite database

`staging/` and `raw/` must be on the same mount so the handoff is an atomic rename. Mount the parent `gutenberg/` directory rather than `raw/` alone; the script refuses to start otherwise.

### 2. Set directory ownership

The container runs as UID/GID `1003:1003` by default. Match this on the host:

```bash
sudo mkdir -p /path/to/ebooks/gutenberg/{raw,staging}
sudo mkdir -p /path/to/gutenberg-sync/db
sudo chown 1003:1003 /path/to/ebooks/gutenberg/{raw,staging}
sudo chown 1003:1003 /path/to/gutenberg-sync/db
```

Change the `user:` field in `docker-compose.yml` if you need a different UID/GID.

### 3. Build and start

```bash
docker compose build gutenberg-sync
docker compose up -d gutenberg-sync
```

### 4. Verify

```bash
docker logs -f gutenberg-sync
```

The first sync takes a long time: at 500 KB/s a full backfill runs for days. Files appear in `raw/` once each fetch finishes, not as they download. If the fetch is interrupted, whatever completed is recorded and moved into `raw/` on the next start.

## Useful commands

```bash
# Total books synced
docker exec gutenberg-sync sqlite3 /db/sync_state.db "SELECT COUNT(*) FROM synced_books;"

# Most recently synced books
docker exec gutenberg-sync sqlite3 /db/sync_state.db \
  "SELECT filename, synced_at FROM synced_books ORDER BY synced_at DESC LIMIT 10;"

# Force a book to be downloaded again on the next cycle
docker exec gutenberg-sync sqlite3 /db/sync_state.db \
  "DELETE FROM synced_books WHERE filename = 'pg1342-images-3.epub';"

# Trigger an immediate sync
docker restart gutenberg-sync
```

## Configuration

Set these under `environment:` in `docker-compose.yml`:

| Variable | Default | Purpose |
|---|---|---|
| `SYNC_INTERVAL` | `86400` (24h) | Seconds between sync cycles |
| `RETRY_INTERVAL` | `300` | Seconds before retrying after a failed listing or fetch |
| `BWLIMIT` | `500` | rsync bandwidth limit in KB/s |
| `RAW` | `/gutenberg/raw` | Where finished EPUBs are handed off |
| `STAGE` | `/gutenberg/staging` | Download area; must be on the same mount as `RAW` |
| `DB` | `/db/sync_state.db` | SQLite database path |

Other settings:

| Setting | Location | Default |
|---|---|---|
| EPUB variant | `*-images-3.epub` pattern in `sync.sh` (3 places) | `*-images-3.epub` |
| Container UID/GID | `user:` in `docker-compose.yml` | `1003:1003` |

## File structure

```
gutenberg-sync/
├── docker-compose.yml
├── Dockerfile
├── sync.sh
└── README.md
```

## License

Do whatever you want with it.
